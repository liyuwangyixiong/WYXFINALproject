"""ARM advisory engine. Values are physical units; absent data stays absent."""
import copy
import math
from collections import deque

CHANNELS = ("hr", "spo2", "body", "room")
LABELS = {"hr": "心率", "spo2": "血氧", "body": "体温", "room": "室温"}
LEVELS = {"normal": "正常", "observe": "观察", "warning": "预警", "alarm": "报警", "insufficient": "数据不足"}

DEFAULTS = {
    "stale_seconds": 5.0,        # 单通道无可信新值的容许时间，秒
    "confirm_seconds": 3.0,      # 持续异常确认时长，秒；同时要求新样本数
    "confirm_samples": 3,        # 持续异常确认所需新样本数，不按程序轮询次数计数
    "recovery_seconds": 2.0,     # 恢复确认时长，秒；仍须收到新样本
    "trend_window_seconds": 10,  # 相邻趋势窗口长度，秒
    "common_window_seconds": 2.0, # 多I2C通道失败证据允许的时间跨度，秒
    "limits": {
        "hr": {"danger_low": 50.0, "low": 60.0, "high": 100.0, "danger_high": 120.0, "trend_delta": 10.0},
        "spo2": {"danger_low": 90.0, "low": 95.0, "high": 100.0, "danger_high": 100.0, "trend_delta": 1.0},
        "body": {"danger_low": 35.0, "low": 36.3, "high": 37.2, "danger_high": 39.0, "trend_delta": 0.3},
        "room": {"danger_low": -40.0, "low": 18.0, "high": 28.0, "danger_high": 85.0, "trend_delta": 2.0},
    },
}


def finite_number(value):
    try:
        return isinstance(value, (float, int)) and not isinstance(value, bool) and math.isfinite(value)
    except OverflowError:
        return False


def validate_settings(value):
    if not isinstance(value, dict) or set(value) != set(DEFAULTS):
        raise ValueError("参数字段不完整或包含未知字段")
    ranges = {"stale_seconds": (1, 300), "confirm_seconds": (1, 120),
              "confirm_samples": (2, 120), "recovery_seconds": (1, 120),
              "trend_window_seconds": (3, 120), "common_window_seconds": (0.5, 10)}
    result = copy.deepcopy(value)
    for name, bounds in ranges.items():
        v = value[name]
        if not finite_number(v) or not bounds[0] <= v <= bounds[1]:
            raise ValueError("参数超出范围：" + name)
        if name in ("confirm_samples", "trend_window_seconds") and int(v) != v:
            raise ValueError("采样数和窗口秒数必须为整数")
        result[name] = int(v) if name in ("confirm_samples", "trend_window_seconds") else float(v)
    limits = value["limits"]
    if not isinstance(limits, dict) or set(limits) != set(CHANNELS):
        raise ValueError("四路阈值必须完整提供")
    bounds = {"hr": (0, 655), "spo2": (0, 100), "body": (-256, 255.99), "room": (-256, 255.99)}
    for ch in CHANNELS:
        row = limits[ch]
        if not isinstance(row, dict) or set(row) != set(DEFAULTS["limits"][ch]):
            raise ValueError("阈值字段错误：" + ch)
        vals = [row[n] for n in ("danger_low", "low", "high", "danger_high")]
        if not all(finite_number(x) for x in vals + [row["trend_delta"]]):
            raise ValueError("阈值必须为有限数值")
        if not (bounds[ch][0] <= vals[0] <= vals[1] < vals[2] <= vals[3] <= bounds[ch][1]):
            raise ValueError(LABELS[ch] + "阈值顺序或单位不正确")
        if not 0 < row["trend_delta"] <= bounds[ch][1]-bounds[ch][0]:
            raise ValueError("趋势变化量不正确")
    return result


class Engine:
    def __init__(self, settings=None):
        self.settings = validate_settings(DEFAULTS if settings is None else settings)
        self.reset()

    def reset(self):
        self.channels = {}
        for ch in CHANNELS:
            self.channels[ch] = {"value": None, "valid": False, "seq": None,
                "last_sample": None, "last_valid": None, "last_comm": None,
                "sample_seq": None, "invalid_reason": None,
                "invalid_since": None, "invalid_samples": 0,
                "comm_error": None, "quality_known": False, "quality_good": None,
                "raw_quality_known": False, "rail_ratio": None, "valid_periods": None,
                "bad_since": None, "bad_samples": 0, "severe_since": None,
                "severe_samples": 0, "recover_since": None, "recover_samples": 0,
                "warning_latched": False, "alarm_latched": False,
                "history": deque(maxlen=2400), "recent_failures": deque(maxlen=64)}
        self.last_packet_at = None
        self.last_packet_seq = None
        self.fpga_state = None
        self.fpga_danger = False
        self.source_label = "未接入"

    def configure(self, settings):
        self.settings = validate_settings(settings)
        # 新阈值重新积累证据，不沿用旧阈值下的计时或趋势。
        self.reset()

    @staticmethod
    def break_run(state):
        for prefix in ("bad", "severe", "recover"):
            state[prefix+"_since"] = None
            state[prefix+"_samples"] = 0

    def ingest(self, packet, now):
        if not isinstance(packet, dict) or not isinstance(packet.get("channels"), dict):
            raise ValueError("数据帧必须包含 channels")
        seq = packet.get("sequence")
        if not isinstance(seq, int) or isinstance(seq, bool) or seq < 0:
            raise ValueError("数据帧 sequence 必须为非负整数")
        if self.last_packet_seq is not None and seq <= self.last_packet_seq:
            raise ValueError("重复或倒退的帧序号；源重启后须显式重置数据源")
        fpga = packet.get("fpga_state")
        if fpga not in (None, "Normal", "Warning", "Danger", "SystemError"):
            raise ValueError("未知 FPGA 状态")
        if not isinstance(packet.get("danger_active",False),bool):
            raise ValueError("danger_active 必须为布尔值")
        parsed = {}
        for ch in CHANNELS:
            row = packet["channels"].get(ch)
            if row is None:
                parsed[ch] = None
                continue
            if not isinstance(row, dict):
                raise ValueError("通道格式错误")
            n = row.get("sequence")
            if not isinstance(n, int) or isinstance(n, bool) or n < 0:
                raise ValueError("每路都需要独立的新样本序号")
            valid = row.get("valid")
            if not isinstance(valid, bool):
                raise ValueError("valid 必须明确为 true 或 false")
            v = row.get("value")
            if valid and not finite_number(v):
                raise ValueError("有效通道必须提供有限数值")
            if not valid and v is not None and not finite_number(v):
                raise ValueError("通道数值格式错误")
            sample_seq = row.get("sample_sequence")
            age = row.get("age_seconds", 0.0)
            if valid and (not isinstance(sample_seq,int) or isinstance(sample_seq,bool) or sample_seq<0):
                raise ValueError("有效值必须提供独立的 sample_sequence")
            if not finite_number(age) or age<0 or age>86400:
                raise ValueError("样本年龄格式错误")
            error = row.get("comm_error")
            if error not in (None, "ok", "nack", "timeout", "sda_stuck", "format"):
                raise ValueError("未知通信结果")
            known = row.get("quality_known", False)
            good = row.get("quality_good")
            raw_known = row.get("raw_quality_known", False)
            rail, periods = row.get("rail_ratio"), row.get("valid_periods")
            if not isinstance(known, bool) or not isinstance(raw_known, bool):
                raise ValueError("质量证据标志必须为布尔值")
            if known and not isinstance(good, bool):
                raise ValueError("已知质量必须提供 quality_good")
            if raw_known and (not finite_number(rail) or not 0 <= rail <= 1 or
                              not isinstance(periods, int) or isinstance(periods, bool) or periods < 0):
                raise ValueError("原始质量证据格式错误")
            parsed[ch] = (row, n, valid, v, error, known, good, raw_known, rail, periods, sample_seq, age)
        self.last_packet_seq = seq
        self.last_packet_at = now
        self.fpga_state, self.fpga_danger = fpga, bool(packet.get("danger_active", False))
        self.source_label = str(packet.get("source_label", "外部数据源"))[:60]
        for ch, item in parsed.items():
            state = self.channels[ch]
            if item is None:
                state["valid"] = False
                state["history"].append((now, None))
                self.break_run(state)
                continue
            row, n, valid, v, error, known, good, raw_known, rail, periods, sample_seq, age = item
            # 状态报告的新序号不能替代传感器自身的新样本序号。
            if state["seq"] is not None and n <= state["seq"]:
                continue
            state.update(seq=n, last_comm=now, comm_error=error,
                         quality_known=known, quality_good=good if known else None,
                         raw_quality_known=raw_known, rail_ratio=rail if raw_known else None,
                         valid_periods=periods if raw_known else None)
            if error in ("nack", "timeout", "sda_stuck"):
                state["recent_failures"].append(now)
            encoding_limits = {"hr":(0,655), "spo2":(0,100), "body":(-256,255.9921875), "room":(-256,255.9921875)}
            lo,hi=encoding_limits[ch]
            encoding_good=finite_number(v) and lo<=v<=hi and (ch not in ("hr","spo2") or v>0)
            raw_bad = raw_known and rail >= 0.30 and periods < 3
            trusted = valid and encoding_good and age<=self.settings["stale_seconds"] and error not in ("nack", "timeout", "sda_stuck", "format") and not raw_bad and not (known and not good)
            state["invalid_reason"] = "encoding" if valid and not encoding_good else None
            if trusted and state["sample_seq"] is not None and sample_seq<=state["sample_seq"]:
                # 新状态报告不能让同一个旧样本变新，也不能累计确认次数。
                continue
            measurement_at = now-age
            if trusted:
                previous = state["last_valid"]
                if previous is not None and measurement_at < previous:
                    state["valid"] = False
                    state["history"].append((now, None))
                    self.break_run(state)
                    continue
                if previous is not None and measurement_at-previous > self.settings["stale_seconds"]:
                    self.break_run(state)
                    state["history"].append((measurement_at, None))
            if valid and sample_seq is not None:
                state["sample_seq"] = sample_seq
                state["last_sample"] = now-age
            state["valid"] = trusted
            state["value"] = float(v) if trusted else None
            state["history"].append((measurement_at, float(v) if trusted else None))
            if not trusted:
                if state["invalid_since"] is None:state["invalid_since"]=now
                state["invalid_samples"]+=1
                self.break_run(state)
                continue
            state["invalid_since"]=None
            state["invalid_samples"]=0
            state["last_valid"] = now-age
            limits = self.settings["limits"][ch]
            abnormal = v < limits["low"] or v > limits["high"]
            severe = ch != "room" and (v < limits["danger_low"] or v > limits["danger_high"])
            for prefix, condition in (("bad", abnormal), ("severe", severe)):
                if condition:
                    if state[prefix+"_since"] is None:
                        state[prefix+"_since"] = measurement_at
                    state[prefix+"_samples"] += 1
                else:
                    state[prefix+"_since"] = None
                    state[prefix+"_samples"] = 0
            sustained = state["bad_since"] is not None and measurement_at-state["bad_since"] >= self.settings["confirm_seconds"] and state["bad_samples"] >= self.settings["confirm_samples"]
            sustained_severe = state["severe_since"] is not None and measurement_at-state["severe_since"] >= self.settings["confirm_seconds"] and state["severe_samples"] >= self.settings["confirm_samples"]
            if sustained:
                state["warning_latched"] = True
            if sustained_severe:
                state["alarm_latched"] = True
            if not abnormal:
                if state["recover_since"] is None:
                    state["recover_since"] = measurement_at
                state["recover_samples"] += 1
                if measurement_at-state["recover_since"] >= self.settings["recovery_seconds"] and state["recover_samples"] >= self.settings["confirm_samples"]:
                    state["warning_latched"] = state["alarm_latched"] = False
            else:
                state["recover_since"] = None
                state["recover_samples"] = 0

    def evaluate(self, now):
        s = self.settings
        packet_fresh = self.last_packet_at is not None and now-self.last_packet_at <= s["stale_seconds"]
        rows = {}
        for ch, state in self.channels.items():
            age = None if state["last_sample"] is None else max(0, now-state["last_sample"])
            valid = packet_fresh and state["valid"] and age is not None and age <= s["stale_seconds"]
            rows[ch] = {"name": LABELS[ch], "value": state["value"] if valid else None,
                "valid": bool(valid), "age_seconds": age,
                "last_valid_age": None if state["last_valid"] is None else max(0,now-state["last_valid"]),
                "sequence": state["seq"], "comm_error": state["comm_error"],
                "sample_sequence": state["sample_seq"],
                "persistent_invalid":bool(not valid and state["invalid_since"] is not None and now-state["invalid_since"]>=s["confirm_seconds"] and state["invalid_samples"]>=s["confirm_samples"]),
                "abnormal_samples":state["bad_samples"],
                "abnormal_duration_seconds":0 if state["bad_since"] is None or state["last_valid"] is None else max(0,state["last_valid"]-state["bad_since"]),
                "quality_known": state["quality_known"], "quality_good": state["quality_good"],
                "raw_quality_known": state["raw_quality_known"],
                "rail_ratio": state["rail_ratio"], "valid_periods": state["valid_periods"],
                "warning": bool(valid and state["warning_latched"]),
                "alarm": bool(valid and state["alarm_latched"]), "trend": "stable"}
            if not valid and age is not None and age>=s["stale_seconds"]+s["confirm_seconds"]:
                rows[ch]["persistent_invalid"]=True
            hist = list(state["history"])
            w = s["trend_window_seconds"]
            # 仅比较时间覆盖充分、无无效间隙的相邻窗口；不压缩缺样时间。
            recent = [(t,v) for t,v in hist if now-2*w <= t <= now]
            if valid and recent and all(v is not None for _,v in recent):
                first = [(t,v) for t,v in recent if t <= now-w]
                last = [(t,v) for t,v in recent if t > now-w]
                no_gap = all(recent[i][0]-recent[i-1][0] <= s["stale_seconds"] for i in range(1,len(recent)))
                if no_gap and len(first)>=3 and len(last)>=3 and first[-1][0]-first[0][0]>=w*0.6 and last[-1][0]-last[0][0]>=w*0.6:
                    def trimmed_mean(items):
                        values=sorted(v for _,v in items)
                        if len(values)>=5:values=values[1:-1]
                        return sum(values)/len(values)
                    delta = trimmed_mean(last)-trimmed_mean(first)
                    if abs(delta)>=s["limits"][ch]["trend_delta"]:
                        rows[ch]["trend"] = "up" if delta>0 else "down"
        valid_set = {ch for ch in CHANNELS if rows[ch]["valid"]}
        # 保持原项目允许的降级组合：四路、任意三路、或仅血氧+体温。
        adequate = len(valid_set)>=3 or valid_set=={"spo2","body"}
        evidence = []

        def add(code, observed, decision, next_step, channels, priority=1):
            evidence.append({"code":code,"observed":observed,"decision":decision,
                             "next_step":next_step,"channels":channels,"priority":priority,
                             "facts":{ch:{"value":rows[ch]["value"],"valid":rows[ch]["valid"],
                                "sample_sequence":rows[ch]["sample_sequence"],
                                "last_valid_age":rows[ch]["last_valid_age"],
                                "comm_error":rows[ch]["comm_error"],
                                "abnormal_samples":rows[ch]["abnormal_samples"],
                                "abnormal_duration_seconds":rows[ch]["abnormal_duration_seconds"],
                                "raw_quality_known":rows[ch]["raw_quality_known"],
                                "rail_ratio":rows[ch]["rail_ratio"],
                                "valid_periods":rows[ch]["valid_periods"],
                                "limits":copy.deepcopy(s["limits"][ch])} for ch in channels}})

        common = []
        for ch in ("spo2","body","room"):
            times = [t for t in self.channels[ch]["recent_failures"] if now-t<=s["common_window_seconds"]]
            if len(times)>=2 and not rows[ch]["valid"]:
                common.append(ch)
        if len(common)==3 and rows["hr"]["valid"]:
            add("COMMON_I2C", "血氧、体温和室温在同一时间窗连续通信失败，独立心率仍更新。",
                "三路I²C数据暂停参与判断，优先怀疑公共链路；尚未确认三颗器件损坏。",
                "先检查公共SDA/SCL、共地和供电，再逐个隔离模块。", common, 4)
        for ch in CHANNELS:
            state, row = self.channels[ch], rows[ch]
            if not row["valid"]:
                if state["invalid_reason"]=="encoding":
                    add("ENCODING_"+ch, LABELS[ch]+"数值超出接口编码范围或为无效占位值。", "不将该值作为正常或生理报警依据。", "检查上游单位、格式及有效标志。", [ch], 3)
                elif state["raw_quality_known"] and state["rail_ratio"] is not None and state["rail_ratio"]>=0.30 and state["valid_periods"]<3:
                    add("RAW_QUALITY_"+ch, LABELS[ch]+"原始信号频繁触底/饱和，有效周期不足。",
                        "当前数值依据不足，暂停使用该通道。", "检查感光面接触、压力、遮光和采集链路。", [ch], 3)
                elif state["comm_error"] in ("nack","timeout","sda_stuck"):
                    add("COMM_"+ch, LABELS[ch]+"出现"+{"nack":"无应答","timeout":"通信超时","sda_stuck":"数据线卡低"}[state["comm_error"]]+"。",
                        "该路当前不可用，不等于已确认硬件损坏。", "检查该模块电源、接触、地址设置及连接。", [ch], 3)
                elif state["quality_known"] and state["quality_good"] is False:
                    add("QUALITY_"+ch, LABELS[ch]+"上游报告数据质量不足。", "暂停使用该路数值。", "复核接触条件和上游质量原因。", [ch], 3)
                else:
                    last = row["last_valid_age"]
                    observed = LABELS[ch]+("尚未收到有效数据。" if last is None else "距最近有效数据已过 %.1f 秒。" % last)
                    add("STALE_"+ch, observed, "该路当前不可用于分级。", "检查数据源、传输和采样是否持续更新。", [ch], 2)
            elif state["alarm_latched"]:
                add("SEVERE_"+ch, LABELS[ch]+"已满足持续严重异常确认；当前值 %g，等待连续恢复确认。" % row["value"], "升级ARM报警提示；保留原FPGA报警。", "优先复核测量条件并按项目处置流程处理。", [ch], 4)
            elif state["warning_latched"]:
                add("PERSISTENT_"+ch, LABELS[ch]+"已满足持续异常确认；当前值 %g，等待连续恢复确认。" % row["value"], "标记持续异常，进入预警。", "复核接触条件并持续观察后续新值。", [ch], 3)
            elif state["bad_since"] is not None:
                add("TRANSIENT_"+ch, LABELS[ch]+"出现短暂范围偏离，尚未满足持续确认。", "保留该可信值，进入观察，不按单点直接升级报警。", "观察接下来的有效新数据。", [ch], 1)
            if row["valid"] and row["trend"]!="stable" and ch!="room":
                direction = "下降" if row["trend"]=="down" else "上升"
                limits=s["limits"][ch]
                v=row["value"]
                worsening = (ch=="spo2" and row["trend"]=="down") or (ch!="spo2" and ((row["trend"]=="up" and v>=(limits["low"]+limits["high"])/2) or (row["trend"]=="down" and v<(limits["low"]+limits["high"])/2)))
                if worsening:
                    add("TREND_"+ch, LABELS[ch]+"相邻完整窗口的均值持续"+direction+"。", "趋势变差提示，不将趋势预测当作实测。", "检查后续窗口是否仍沿同一方向变化。", [ch], 2)
        abnormal_human = [ch for ch in ("hr","spo2","body") if rows[ch]["warning"]]
        if len(abnormal_human)>=2:
            add("MULTI_PERSISTENT", "多项可信人体指标同时满足持续异常条件。", "按预设规则升级ARM报警提示。", "优先复核多项测量与当前环境条件。", abnormal_human, 4)
        danger = packet_fresh and (self.fpga_danger or self.fpga_state=="Danger")
        fpga_system_error = packet_fresh and self.fpga_state=="SystemError"
        if danger:
            add("FPGA_DANGER", "FPGA独立危险告警有效。", "保留危险告警，不因其他数据不足而屏蔽。", "优先按既有报警流程处理。", [], 5)
        elif packet_fresh and self.fpga_state=="Warning":
            add("FPGA_WARNING", "FPGA报告Warning状态。", "保留原预警，不以ARM正常值覆盖。", "复核原有FPGA告警原因。", [], 3)
        if not adequate or fpga_system_error:
            add("INSUFFICIENT", "当前可信通道组合不足，或FPGA报告System Error。", "不输出全面正常结论；已有可信危险告警仍保留。", "恢复缺失通道，再进行完整分级。", [ch for ch in CHANNELS if not rows[ch]["valid"]], 3)
        if danger or any(row["alarm"] for row in rows.values()) or len(abnormal_human)>=2:
            level="alarm"
        elif not adequate or fpga_system_error:
            level="insufficient"
        elif any(row["warning"] or row["persistent_invalid"] for row in rows.values()) or any(e["code"].startswith("TREND_") for e in evidence) or (packet_fresh and self.fpga_state=="Warning"):
            level="warning"
        elif evidence or len(valid_set)<4:
            level="observe"
        else:
            level="normal"
        if not evidence:
            add("CLEAR", "各路新数据在有效时限内，尚未发现持续异常。", "按当前可观测范围继续监测。", "保持采样与数据链路正常。", [], 0)
        evidence.sort(key=lambda e:e["priority"],reverse=True)
        return {"level":level,"level_label":LEVELS[level],"channels":rows,
            "valid_count":len(valid_set),"assessment_valid":bool(adequate and not fpga_system_error),
            "data_insufficient":bool(not adequate or fpga_system_error),"degraded":len(valid_set)<4,
            "danger_active":bool(danger or any(row["alarm"] for row in rows.values()) or len(abnormal_human)>=2),
            "fpga_state":self.fpga_state if packet_fresh else None,
            "packet_age_seconds":None if self.last_packet_at is None else max(0,now-self.last_packet_at),
            "source_label":self.source_label,"evidence":evidence}
