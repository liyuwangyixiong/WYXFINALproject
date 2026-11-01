#!/usr/bin/env python3
"""ARM-only evidence and advisory process. No web server or FPGA access."""
import argparse
import copy
import json
import os
from pathlib import Path
import queue
import signal
import sys
import threading
import time

from engine import Engine,validate_settings
from simulator import Simulator,SCENARIOS
from storage import Store,stamp


class Monitor:
    def __init__(self,data_dir,mode="external",scenario="normal",settings=None,now=None):
        if mode not in ("demo","external"):raise ValueError("Unknown input mode")
        data_dir=Path(data_dir)
        data_dir.mkdir(parents=True,exist_ok=True)
        started=time.monotonic() if now is None else now
        self.store=Store(data_dir/"monitor.sqlite3")
        try:
            config=validate_settings(settings) if settings is not None else self.store.load_settings()
            if settings is not None:self.store.save_settings(config)
            self.engine=Engine(config)
            self.simulator=Simulator(scenario,started) if mode=="demo" else None
        except Exception:
            self.store.close()
            raise
        self.mode=mode
        self.scenario=scenario if mode=="demo" else ""
        self.last_key=None
        self.last_state=None
        self.source_generation=1
        self.store.event(mode,"system","observe","START", "ARM判断进程启动；"+("输入为明确标注的模拟数据。" if mode=="demo" else "等待外部数据，不生成模拟替代值。"))

    def ingest(self,packet,now=None):
        if self.mode!="external":raise ValueError("Cannot mix external input with demo mode")
        now=time.monotonic() if now is None else now
        if isinstance(packet,dict) and packet.get("event")=="source_restart":
            self.engine.reset()
            self.source_generation+=1
            self.last_key=None
            self.store.event(self.mode,"source","observe","SOURCE_RESTART","外部输入显式报告源重启。","清除旧序号、历史窗口和持续判断，等待新数据。")
            return
        if isinstance(packet,dict) and packet.get("event")=="HELP":
            self.record_help()
            return
        self.engine.ingest(packet,now)

    def record_help(self):
        ident=self.store.event(self.mode,"help","alarm","HELP","使用者触发HELP求助。","已本地记录，未连接远端发送器。","按项目求助流程处理。")
        return {"id":ident,"kind":"HELP","timestamp":stamp(),"source_mode":self.mode,"delivery":"local_only"}

    def step(self,now=None):
        now=time.monotonic() if now is None else now
        if self.simulator:
            packet=self.simulator.demo_packet(now)
            if packet is not None:self.engine.ingest(packet,now)
        state=self.engine.evaluate(now)
        state.update(timestamp=stamp(),source_mode=self.mode,demo=self.mode=="demo",
                     scenario=self.scenario or None,source_generation=self.source_generation,
                     advisory_only=True)
        key=(state["level"],tuple(e["code"] for e in state["evidence"]),self.source_generation)
        state["state_changed"]=key!=self.last_key
        if key!=self.last_key:
            for item in state["evidence"]:
                self.store.event(self.mode,"diagnosis",state["level"],item["code"],item["observed"],item["decision"],item["next_step"],facts=item["facts"])
            self.last_key=key
        self.store.add_sample(state,self.mode,self.scenario)
        self.last_state=state
        return copy.deepcopy(state)

    def close(self):
        self.store.close()


def read_input(path,out,stop,from_start=False):
    """Read complete JSONL records. Existing regular-file history is not replayed."""
    def publish(kind,item):
        received=time.monotonic()
        while not stop.is_set():
            try:out.put((kind,item,received),timeout=.2);return
            except queue.Full:continue
    is_stdin=path=="-"
    stream=sys.stdin if is_stdin else open(path,"r",encoding="utf-8")
    try:
        if not is_stdin and not from_start:stream.seek(0,os.SEEK_END)
        publish("ready",path)
        buffer=""
        dropping=False
        while not stop.is_set():
            chunk=stream.readline(65537)
            if not chunk:
                if is_stdin:break
                if stream.tell()>os.fstat(stream.fileno()).st_size:
                    stream.seek(0)
                    publish("error","Input truncated; require source_restart record before reset sequences")
                    buffer="";dropping=False
                stop.wait(.1)
                continue
            if dropping:
                if chunk.endswith("\n"):dropping=False
                continue
            buffer+=chunk
            if len(buffer)>65536:
                publish("error","Input record exceeds 65536 characters")
                buffer="";dropping=not chunk.endswith("\n")
                continue
            if not buffer.endswith("\n"):continue
            try:record=json.loads(buffer)
            except ValueError:
                publish("error","Invalid JSON input record");buffer="";continue
            buffer=""
            publish("packet",record)
    finally:
        if not is_stdin:stream.close()


def main(argv=None):
    parser=argparse.ArgumentParser(description="WYX ARM evidence monitor; FPGA and web server are not accessed")
    parser.add_argument("--mode",choices=("demo","external"),default=os.environ.get("WYX_MODE","external"))
    parser.add_argument("--scenario",choices=sorted(SCENARIOS),default="normal")
    parser.add_argument("--input",default=os.environ.get("WYX_INPUT",""),metavar="JSONL_FILE_OR_DASH")
    parser.add_argument("--from-start",action="store_true",help="Explicitly consume existing file records; source must provide correct age_seconds")
    parser.add_argument("--data-dir",type=Path,default=Path(__file__).resolve().parent/"data")
    parser.add_argument("--settings",type=Path)
    parser.add_argument("--duration",type=float,default=0,help="Run seconds; zero means continuously")
    parser.add_argument("--export",choices=("samples","events"))
    parser.add_argument("--output",type=Path)
    parser.add_argument("--help-event",action="store_true")
    args=parser.parse_args(argv)
    if args.export:
        if not args.output:parser.error("--export requires --output")
        if not (args.data_dir/"monitor.sqlite3").is_file():parser.error("No recorded database")
        store=Store(args.data_dir/"monitor.sqlite3")
        try:args.output.write_bytes(store.export(args.export))
        finally:store.close()
        print(str(args.output.resolve()))
        return 0
    if not args.help_event and args.mode=="external" and not args.input:parser.error("External mode requires --input; simulation fallback is disabled")
    if not args.help_event and args.mode=="external" and args.input!="-" and not Path(args.input).is_file():parser.error("Input JSONL file does not exist")
    if not 0<=args.duration<=86400:parser.error("--duration must be 0..86400 seconds")
    settings=validate_settings(json.loads(args.settings.read_text(encoding="utf-8-sig"))) if args.settings else None
    monitor=Monitor(args.data_dir,args.mode,args.scenario,settings)
    if args.help_event:
        print(json.dumps(monitor.record_help(),ensure_ascii=False),flush=True)
        monitor.close()
        return 0
    stop=threading.Event()
    pending=queue.Queue(maxsize=64)
    if args.mode=="external":
        def reader():
            try:read_input(args.input,pending,stop,args.from_start)
            except (OSError,UnicodeError) as exc:
                while not stop.is_set():
                    try:pending.put(("error","Input unavailable: "+str(exc),time.monotonic()),timeout=.2);break
                    except queue.Full:continue
        threading.Thread(target=reader,name="wyx-input",daemon=True).start()
    def terminate(signum,frame):stop.set()
    signal.signal(signal.SIGTERM,terminate)
    signal.signal(signal.SIGINT,terminate)
    began=time.monotonic()
    ticks=0
    try:
        while not stop.is_set():
            now=time.monotonic()
            if args.duration and now-began>=args.duration:break
            for _ in range(64):
                try:kind,item,received=pending.get_nowait()
                except queue.Empty:break
                if kind=="packet":
                    try:monitor.ingest(item,received)
                    except (ValueError,TypeError) as exc:
                        print("INPUT_REJECTED "+str(exc),file=sys.stderr,flush=True)
                elif kind=="ready":print("INPUT_READY "+item,file=sys.stderr,flush=True)
                else:print("INPUT_ERROR "+item,file=sys.stderr,flush=True)
            state=monitor.step(now)
            print(json.dumps(state,ensure_ascii=False,allow_nan=False),flush=True)
            ticks+=1
            if ticks%3600==0:monitor.store.prune()
            stop.wait(max(.01,1-(time.monotonic()-now)))
    finally:
        stop.set()
        monitor.close()
    return 0


if __name__=="__main__":
    sys.exit(main())
