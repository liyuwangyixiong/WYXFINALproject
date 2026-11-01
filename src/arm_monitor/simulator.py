import math
from engine import CHANNELS

SCENARIOS = {
    "normal": "正常稳定", "spike": "一次血氧波动", "persistent_spo2": "血氧持续偏低",
    "multi": "多项指标持续异常", "common_i2c": "三路 I²C 公共链路故障",
    "body_missing": "体温单通道无数据", "room_missing": "室温单通道无数据",
    "hr_quality": "心率原始质量不足", "flat_fresh": "数值平稳但持续更新",
    "stale": "数据源停止更新", "worsening": "血氧持续下降", "recovering": "异常后恢复",
}

class Simulator:
    def __init__(self,scenario="normal",now=0.0):
        if scenario not in SCENARIOS:raise ValueError("Unknown simulation scenario")
        self.scenario=scenario
        self.started=now
        self.sequence=0
        self.channel_sequences={ch:0 for ch in CHANNELS}

    def demo_packet(self, now):
        elapsed = now-self.started
        # 演示数值只是模拟输入，不使用个人测量数据，也不代表实际板卡读数。
        values = {"hr":74+2*math.sin(elapsed/8), "spo2":98.1+0.2*math.sin(elapsed/11),
                  "body":36.65+0.04*math.sin(elapsed/15), "room":24.3+0.1*math.sin(elapsed/20)}
        bad = set()
        errors = {}
        scenario = self.scenario
        if scenario=="stale" and elapsed>3:
            return None
        if scenario=="spike" and 2<=elapsed<3:
            values["spo2"]=88
        elif scenario=="persistent_spo2":
            values["spo2"]=92.5+0.1*math.sin(elapsed/5)
        elif scenario=="multi":
            values.update(spo2=92.5, hr=110.0)
        elif scenario=="common_i2c":
            bad={"spo2","body","room"}
            errors={ch:"nack" for ch in bad}
        elif scenario=="body_missing":
            bad={"body"};errors={"body":"nack"}
        elif scenario=="room_missing":
            bad={"room"};errors={"room":"nack"}
        elif scenario=="flat_fresh":
            values={"hr":74,"spo2":98,"body":36.6,"room":24.3}
        elif scenario=="worsening":
            values["spo2"]=max(91,99-elapsed*0.08)
        elif scenario=="recovering" and elapsed<8:
            values["spo2"]=92.3
        if scenario=="hr_quality":
            bad.add("hr")
        self.sequence+=1
        rows={}
        for ch in CHANNELS:
            self.channel_sequences[ch]+=1
            rows[ch]={"sequence":self.channel_sequences[ch],"sample_sequence":self.channel_sequences[ch],
                "age_seconds":0.0,"value":None if ch in bad else round(values[ch],3),
                "valid":ch not in bad,"comm_error":errors.get(ch,"ok"),
                "quality_known":True,"quality_good":ch not in bad,
                "raw_quality_known":scenario=="hr_quality" and ch=="hr",
                "rail_ratio":0.75 if scenario=="hr_quality" and ch=="hr" else None,
                "valid_periods":1 if scenario=="hr_quality" and ch=="hr" else None}
        return {"sequence":self.sequence,"source_label":"模拟输入 · "+SCENARIOS[scenario],
                "fpga_state":None,"danger_active":False,"channels":rows}
