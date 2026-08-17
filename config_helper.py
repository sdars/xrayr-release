#!/usr/bin/env python3
"""
XrayR Config Helper - handles YAML/JSON config operations
Usage: python3 config_helper.py <command> [args...]
"""
import sys
import os
import json
import copy

try:
    import yaml
except ImportError:
    print('ERROR: PyYAML not installed. Run: pip3 install pyyaml')
    sys.exit(1)

CONFIG_DIR = '/etc/XrayR'
CONFIG_FILE = os.path.join(CONFIG_DIR, 'config.yml')
ROUTE_FILE = os.path.join(CONFIG_DIR, 'route.json')
DNS_FILE = os.path.join(CONFIG_DIR, 'dns.json')
OUTBOUND_FILE = os.path.join(CONFIG_DIR, 'custom_outbound.json')
INBOUND_FILE = os.path.join(CONFIG_DIR, 'custom_inbound.json')

def load_config():
    if not os.path.exists(CONFIG_FILE):
        return None
    with open(CONFIG_FILE, 'r') as f:
        return yaml.safe_load(f)

def save_config(cfg):
    with open(CONFIG_FILE, 'w') as f:
        yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

def load_json(path):
    if not os.path.exists(path):
        return None
    with open(path, 'r') as f:
        return json.load(f)

def save_json(path, data):
    with open(path, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print(f'OK: {path}')

# ========== Node Management ==========

# 中文标签映射
_PANEL_LABELS = {
    "SSpanel": "SSpanel",
    "NewV2board": "新版 V2board",
    "V2board": "V2board",
    "PMpanel": "PMpanel",
    "Proxypanel": "Proxypanel",
    "V2RaySocks": "V2RaySocks",
    "GoV2Panel": "GoV2Panel",
    "BunPanel": "BunPanel",
}
_PROTO_LABELS = {
    "V2ray": "V2Ray",
    "Vmess": "VMess",
    "Vless": "VLESS",
    "Shadowsocks": "Shadowsocks",
    "Trojan": "Trojan",
    "Shadowsocks-Plugin": "Shadowsocks-Plugin",
    "Hysteria2": "Hysteria2",
}

def _norm_list(s):
    """将中英文逗号、空格、分号、顿号、竖线等归一化为逗号分隔的列表。"""
    import re as _re
    if not s:
        return []
    parts = _re.split(r"[,，、;；|｜\s]+", str(s).strip())
    return [p for p in (p.strip() for p in parts) if p]

def _check_node_reachable(host, timeout=3):
    """HTTP HEAD/GET 检查节点 API 是否可达, 返回 (ok, msg)。"""
    try:
        from urllib.request import Request, urlopen
        from urllib.parse import urlparse
        import ssl
        u = urlparse(host)
        if not u.scheme:
            host = "http://" + host
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        req = Request(host, method="GET", headers={"User-Agent": "XrayR-HealthCheck/1.0"})
        with urlopen(req, timeout=timeout, context=ctx) as resp:
            return True, f"HTTP {resp.status}"
    except Exception as e:
        msg = str(e)
        if len(msg) > 40:
            msg = msg[:40] + "..."
        return False, msg

def list_nodes():
    cfg = load_config()
    if not cfg:
        print('NO_NODES')
        return
    enabled = cfg.get('Nodes') or []
    disabled = cfg.get('DisabledNodes') or []
    if not enabled and not disabled:
        print('NO_NODES')
        return
    # 输出格式: idx|status|panel|host|node_id|node_type
    # status: enabled / disabled
    for i, node in enumerate(enabled):
        api = node.get('ApiConfig', {}) or {}
        panel = node.get('PanelType', 'Unknown')
        host = api.get('ApiHost', 'N/A')
        nid = api.get('NodeID', 'N/A')
        ntype = api.get('NodeType', 'N/A')
        print(f'{i}|enabled|{panel}|{host}|{nid}|{ntype}')
    base = len(enabled)
    for j, node in enumerate(disabled):
        api = node.get('ApiConfig', {}) or {}
        panel = node.get('PanelType', 'Unknown')
        host = api.get('ApiHost', 'N/A')
        nid = api.get('NodeID', 'N/A')
        ntype = api.get('NodeType', 'N/A')
        print(f'{base+j}|disabled|{panel}|{host}|{nid}|{ntype}')

def _resolve_node(cfg, idx):
    """把总索引解析回 (list_name, list_ref, local_idx)。"""
    enabled = cfg.get('Nodes') or []
    disabled = cfg.get('DisabledNodes') or []
    if idx < len(enabled):
        return 'Nodes', enabled, idx
    idx2 = idx - len(enabled)
    if idx2 < len(disabled):
        return 'DisabledNodes', disabled, idx2
    return None, None, -1

def check_nodes():
    """并发检测所有节点 API 可用性。"""
    cfg = load_config()
    if not cfg:
        print('NO_NODES')
        return
    enabled = cfg.get('Nodes') or []
    disabled = cfg.get('DisabledNodes') or []
    all_nodes = [(i, n, 'enabled') for i, n in enumerate(enabled)]
    base = len(enabled)
    all_nodes += [(base+i, n, 'disabled') for i, n in enumerate(disabled)]
    if not all_nodes:
        print('NO_NODES')
        return
    from concurrent.futures import ThreadPoolExecutor, as_completed
    def _one(item):
        idx, node, status = item
        api = node.get('ApiConfig', {}) or {}
        host = api.get('ApiHost', '')
        ok, msg = _check_node_reachable(host, timeout=5)
        return idx, status, host, ok, msg
    with ThreadPoolExecutor(max_workers=min(8, len(all_nodes))) as ex:
        futs = [ex.submit(_one, x) for x in all_nodes]
        results = [f.result() for f in as_completed(futs)]
    results.sort(key=lambda x: x[0])
    for idx, status, host, ok, msg in results:
        state = 'ok' if ok else 'fail'
        print(f'{idx}|{status}|{state}|{host}|{msg}')

def enable_node(idx):
    cfg = load_config()
    if not cfg:
        print('ERROR: No config')
        return
    idx = int(idx)
    lst_name, lst, li = _resolve_node(cfg, idx)
    if lst_name is None:
        print('ERROR: Invalid index')
        return
    if lst_name == 'Nodes':
        print('WARN: 节点已启用')
        return
    node = lst.pop(li)
    cfg.setdefault('Nodes', [])
    if cfg['Nodes'] is None:
        cfg['Nodes'] = []
    cfg['Nodes'].append(node)
    save_config(cfg)
    print(f'OK: 节点已启用')

def disable_node(idx):
    cfg = load_config()
    if not cfg:
        print('ERROR: No config')
        return
    idx = int(idx)
    lst_name, lst, li = _resolve_node(cfg, idx)
    if lst_name is None:
        print('ERROR: Invalid index')
        return
    if lst_name == 'DisabledNodes':
        print('WARN: 节点已禁用')
        return
    node = lst.pop(li)
    cfg.setdefault('DisabledNodes', [])
    if cfg['DisabledNodes'] is None:
        cfg['DisabledNodes'] = []
    cfg['DisabledNodes'].append(node)
    save_config(cfg)
    print(f'OK: 节点已禁用')

def show_node(idx):
    cfg = load_config()
    if not cfg:
        print('ERROR: No config')
        return
    idx = int(idx)
    lst_name, lst, li = _resolve_node(cfg, idx)
    if lst_name is None:
        print('ERROR: Invalid index')
        return
    node = lst[li]
    api = node.get('ApiConfig', {}) or {}
    ctl = node.get('ControllerConfig', {}) or {}
    cert = (ctl.get('CertConfig') or {})
    autosl = (ctl.get('AutoSpeedLimitConfig') or {})
    gdlc = (ctl.get('GlobalDeviceLimitConfig') or {})
    panel = node.get('PanelType', 'Unknown')
    panel_zh = _PANEL_LABELS.get(panel, panel)
    ntype = api.get('NodeType', 'N/A')
    ntype_zh = _PROTO_LABELS.get(ntype, ntype)
    status_zh = '已启用' if lst_name == 'Nodes' else '已禁用'
    host = api.get('ApiHost', '')
    reachable_ok, reachable_msg = _check_node_reachable(host, timeout=3)
    reachable_zh = f'可达 ({reachable_msg})' if reachable_ok else f'不可达 ({reachable_msg})'
    def _yn(v):
        return '是' if v else '否'
    lines = []
    lines.append('┌─── 基础信息 ───────────────────────────────────┐')
    lines.append(f'  面板类型      : {panel_zh} ({panel})')
    lines.append(f'  节点协议      : {ntype_zh} ({ntype})')
    lines.append(f'  节点 ID       : {api.get("NodeID", "N/A")}')
    lines.append(f'  运行状态      : {status_zh}')
    lines.append(f'  API 可达性    : {reachable_zh}')
    lines.append('')
    lines.append('┌─── API 配置 ───────────────────────────────────┐')
    lines.append(f'  API 地址      : {host}')
    lines.append(f'  API 密钥      : {api.get("ApiKey", "")}')
    lines.append(f'  超时秒数      : {api.get("Timeout", 30)}')
    lines.append(f'  启用 VLESS    : {_yn(api.get("EnableVless"))}')
    lines.append(f'  限速 (Mbps)   : {api.get("SpeedLimit", 0)}')
    lines.append(f'  设备数限制    : {api.get("DeviceLimit", 0)}')
    if api.get('RuleListPath'):
        lines.append(f'  规则文件      : {api.get("RuleListPath")}')
    lines.append('')
    lines.append('┌─── 控制器配置 ─────────────────────────────────┐')
    lines.append(f'  监听 IP       : {ctl.get("ListenIP", "0.0.0.0")}')
    lines.append(f'  发送 IP       : {ctl.get("SendIP", "0.0.0.0")}')
    lines.append(f'  更新间隔 (秒) : {ctl.get("UpdatePeriodic", 60)}')
    lines.append(f'  启用 DNS      : {_yn(ctl.get("EnableDNS"))}')
    lines.append(f'  DNS 策略      : {ctl.get("DNSType", "AsIs")}')
    lines.append(f'  代理协议      : {_yn(ctl.get("EnableProxyProtocol"))}')
    lines.append(f'  启用回落      : {_yn(ctl.get("EnableFallback"))}')
    lines.append('')
    lines.append('┌─── 自动限速 ───────────────────────────────────┐')
    lines.append(f'  触发阈值      : {autosl.get("Limit", 0)}')
    lines.append(f'  警告次数      : {autosl.get("WarnTimes", 0)}')
    lines.append(f'  限速速度      : {autosl.get("LimitSpeed", 0)}')
    lines.append(f'  限速时长      : {autosl.get("LimitDuration", 0)}')
    lines.append('')
    lines.append('┌─── 全局设备限制 (Redis) ───────────────────────┐')
    lines.append(f'  启用          : {_yn(gdlc.get("Enable"))}')
    lines.append(f'  Redis 地址    : {gdlc.get("RedisAddr", "127.0.0.1:6379")}')
    lines.append(f'  Redis 密码    : {"(已设置)" if gdlc.get("RedisPassword") else "(未设置)"}')
    lines.append(f'  Redis DB      : {gdlc.get("RedisDB", 0)}')
    lines.append(f'  超时秒数      : {gdlc.get("Timeout", 5)}')
    lines.append(f'  过期秒数      : {gdlc.get("Expiry", 60)}')
    lines.append('')
    lines.append('┌─── 证书配置 ───────────────────────────────────┐')
    lines.append(f'  证书模式      : {cert.get("CertMode", "none")}')
    lines.append(f'  证书域名      : {cert.get("CertDomain", "")}')
    lines.append(f'  证书文件      : {cert.get("CertFile", "")}')
    lines.append(f'  密钥文件      : {cert.get("KeyFile", "")}')
    lines.append(f'  ACME Provider : {cert.get("Provider", "")}')
    lines.append(f'  ACME 邮箱     : {cert.get("Email", "")}')
    print("\n".join(lines))


def get_node_fields(idx):
    """Return editable fields as tab-separated lines: num|field_path|zh_name|current_value"""
    cfg = load_config()
    if not cfg:
        print('ERROR: No config')
        return
    idx = int(idx)
    lst_name, lst, li = _resolve_node(cfg, idx)
    if lst_name is None:
        print('ERROR: Invalid index')
        return
    node = lst[li]
    api = node.get('ApiConfig', {}) or {}
    ctl = node.get('ControllerConfig', {}) or {}
    cert = (ctl.get('CertConfig') or {})
    autosl = (ctl.get('AutoSpeedLimitConfig') or {})
    gdlc = (ctl.get('GlobalDeviceLimitConfig') or {})
    panel = node.get('PanelType', 'Unknown')
    def _yn(v):
        return '是' if v else '否'
    def _bool_raw(v):
        return 'true' if v else 'false'
    fields = [
        ('PanelType',                          'API 配置', '面板类型',    panel, ['NewV2board','V2board','PMpanel','Proxypanel','V2RaySocks','SSpanel','GoV2Panel','BunPanel']),
        ('ApiConfig.ApiHost',                  'API 配置', '面板地址',    api.get('ApiHost',''), None),
        ('ApiConfig.ApiKey',                   'API 配置', 'API 密钥',   api.get('ApiKey',''), None),
        ('ApiConfig.NodeID',                   'API 配置', '节点 ID',    str(api.get('NodeID',0)), None),
        ('ApiConfig.NodeType',                 'API 配置', '节点类型',    api.get('NodeType',''), ['V2ray','Vmess','Vless','Trojan','Shadowsocks','Shadowsocks-Plugin','Hysteria2']),
        ('ApiConfig.Timeout',                  'API 配置', '超时秒数',    str(api.get('Timeout',30)), None),
        ('ApiConfig.EnableVless',              'API 配置', '启用 VLESS',  _bool_raw(api.get('EnableVless')), ['true','false']),
        ('ApiConfig.SpeedLimit',               'API 配置', '限速(Mbps)',  str(api.get('SpeedLimit',0)), None),
        ('ApiConfig.DeviceLimit',              'API 配置', '设备限制',    str(api.get('DeviceLimit',0)), None),
        ('ControllerConfig.ListenIP',          '控制器',   '监听 IP',    ctl.get('ListenIP','0.0.0.0'), None),
        ('ControllerConfig.SendIP',            '控制器',   '发送 IP',    ctl.get('SendIP','0.0.0.0'), None),
        ('ControllerConfig.UpdatePeriodic',    '控制器',   '更新间隔(秒)', str(ctl.get('UpdatePeriodic',60)), None),
        ('ControllerConfig.EnableDNS',         '控制器',   '启用 DNS',   _bool_raw(ctl.get('EnableDNS')), ['true','false']),
        ('ControllerConfig.DNSType',           '控制器',   'DNS 策略',   ctl.get('DNSType','AsIs'), ['AsIs','UseIP','UseIPv4','UseIPv6']),
        ('ControllerConfig.EnableProxyProtocol','控制器',   '代理协议',   _bool_raw(ctl.get('EnableProxyProtocol')), ['true','false']),
        ('ControllerConfig.EnableFallback',    '控制器',   '启用回落',   _bool_raw(ctl.get('EnableFallback')), ['true','false']),
        ('ControllerConfig.AutoSpeedLimitConfig.Limit',       '自动限速', '触发阈值',  str(autosl.get('Limit',0)), None),
        ('ControllerConfig.AutoSpeedLimitConfig.WarnTimes',   '自动限速', '警告次数',  str(autosl.get('WarnTimes',0)), None),
        ('ControllerConfig.AutoSpeedLimitConfig.LimitSpeed',  '自动限速', '限速速度',  str(autosl.get('LimitSpeed',0)), None),
        ('ControllerConfig.AutoSpeedLimitConfig.LimitDuration','自动限速', '限速时长',  str(autosl.get('LimitDuration',0)), None),
        ('ControllerConfig.GlobalDeviceLimitConfig.Enable',   '设备限制(Redis)', '启用', _bool_raw(gdlc.get('Enable')), ['true','false']),
        ('ControllerConfig.GlobalDeviceLimitConfig.RedisAddr', '设备限制(Redis)', 'Redis地址', gdlc.get('RedisAddr','127.0.0.1:6379'), None),
        ('ControllerConfig.GlobalDeviceLimitConfig.RedisPassword','设备限制(Redis)', 'Redis密码', gdlc.get('RedisPassword',''), None),
        ('ControllerConfig.GlobalDeviceLimitConfig.RedisDB',  '设备限制(Redis)', 'Redis DB', str(gdlc.get('RedisDB',0)), None),
        ('ControllerConfig.GlobalDeviceLimitConfig.Timeout',  '设备限制(Redis)', '超时秒数', str(gdlc.get('Timeout',5)), None),
        ('ControllerConfig.GlobalDeviceLimitConfig.Expiry',   '设备限制(Redis)', '过期秒数', str(gdlc.get('Expiry',60)), None),
        ('ControllerConfig.CertConfig.CertMode',   '证书配置', '证书模式', cert.get('CertMode','none'), ['none','file','http','tls','dns']),
        ('ControllerConfig.CertConfig.CertDomain', '证书配置', '证书域名', cert.get('CertDomain',''), None),
        ('ControllerConfig.CertConfig.CertFile',   '证书配置', '证书文件', cert.get('CertFile',''), None),
        ('ControllerConfig.CertConfig.KeyFile',    '证书配置', '密钥文件', cert.get('KeyFile',''), None),
        ('ControllerConfig.CertConfig.Provider',   '证书配置', 'ACME提供商', cert.get('Provider',''), ['cloudflare','alidns','dnspod','namesilo','']),
        ('ControllerConfig.CertConfig.Email',      '证书配置', 'ACME邮箱', cert.get('Email',''), None),
    ]
    for i, (path, cat, name, val, opts) in enumerate(fields):
        opts_str = ','.join(opts) if opts else ''
        print(f'{i+1}|{path}|{cat}|{name}|{val}|{opts_str}')

def add_node(panel_type, api_host, api_key, node_id, node_type):
    cfg = load_config()
    if not cfg:
        cfg = {'Nodes': []}
    if 'Nodes' not in cfg or cfg['Nodes'] is None:
        cfg['Nodes'] = []

    node = {
        'PanelType': panel_type,
        'ApiConfig': {
            'ApiHost': api_host,
            'ApiKey': api_key,
            'NodeID': int(node_id),
            'NodeType': node_type,
            'Timeout': 30,
            'EnableVless': False,
            'SpeedLimit': 0,
            'DeviceLimit': 0,
        },
        'ControllerConfig': {
            'ListenIP': '0.0.0.0',
            'SendIP': '0.0.0.0',
            'UpdatePeriodic': 60,
            'EnableDNS': False,
            'DNSType': 'AsIs',
            'EnableProxyProtocol': False,
            'AutoSpeedLimitConfig': {
                'Limit': 0,
                'WarnTimes': 0,
                'LimitSpeed': 0,
                'LimitDuration': 0,
            },
            'GlobalDeviceLimitConfig': {
                'Enable': False,
                'RedisAddr': '127.0.0.1:6379',
                'RedisPassword': '',
                'RedisDB': 0,
                'Timeout': 5,
                'Expiry': 60,
            },
            'EnableFallback': False,
            'CertConfig': {
                'CertMode': 'none',
                'CertDomain': '',
                'CertFile': '',
                'KeyFile': '',
                'Provider': '',
                'Email': '',
            },
        },
    }
    cfg['Nodes'].append(node)
    save_config(cfg)
    print(f'OK: Node added (index {len(cfg["Nodes"])-1})')

def delete_node(idx):
    cfg = load_config()
    idx = int(idx)
    if not cfg:
        print('ERROR: No config')
        return
    lst_name, lst, li = _resolve_node(cfg, idx)
    if lst_name is None:
        print('ERROR: Invalid index')
        return
    removed = lst.pop(li)
    save_config(cfg)
    host = (removed.get('ApiConfig') or {}).get('ApiHost', 'N/A')
    print(f'OK: 节点 {idx} 已删除 ({host})')

def modify_node(idx, field, value):
    cfg = load_config()
    idx = int(idx)
    if not cfg:
        print('ERROR: No config')
        return
    lst_name, lst, li = _resolve_node(cfg, idx)
    if lst_name is None:
        print('ERROR: Invalid index')
        return
    node = lst[li]
    # field format: ApiConfig.ApiHost or ControllerConfig.EnableDNS
    parts = field.split('.')
    obj = node
    for p in parts[:-1]:
        if p not in obj:
            obj[p] = {}
        obj = obj[p]
    # Type conversion
    key = parts[-1]
    if value.lower() == 'true':
        value = True
    elif value.lower() == 'false':
        value = False
    elif value.isdigit():
        value = int(value)
    obj[key] = value
    save_config(cfg)
    print(f'OK: Node {idx} {field} = {value}')

# ========== Route Management ==========

def list_routes():
    data = load_json(ROUTE_FILE)
    if not data or 'rules' not in data:
        print('NO_RULES')
        return
    print(f'Strategy: {data.get("domainStrategy", "N/A")}')
    for i, rule in enumerate(data['rules']):
        tag = rule.get('outboundTag', 'N/A')
        rtype = []
        if 'domain' in rule: rtype.append(f"domain:{len(rule['domain'])}")
        if 'ip' in rule: rtype.append(f"ip:{len(rule['ip'])}")
        if 'protocol' in rule: rtype.append(f"proto:{','.join(rule['protocol'])}")
        if 'network' in rule: rtype.append(f"net:{rule['network']}")
        print(f'{i}|{tag}|{" ".join(rtype)}')

def add_route_rule(outbound_tag, rule_type, rule_value):
    data = load_json(ROUTE_FILE)
    if not data:
        data = {'domainStrategy': 'IPIfNonMatch', 'rules': []}
    if 'rules' not in data:
        data['rules'] = []
    rule = {'type': 'field', 'outboundTag': outbound_tag}
    if rule_type == 'domain':
        rule['domain'] = _norm_list(rule_value)
    elif rule_type == 'ip':
        rule['ip'] = _norm_list(rule_value)
    elif rule_type == 'protocol':
        rule['protocol'] = _norm_list(rule_value)
    elif rule_type == 'network':
        rule['network'] = rule_value
    data['rules'].append(rule)
    save_json(ROUTE_FILE, data)

def delete_route_rule(idx):
    data = load_json(ROUTE_FILE)
    idx = int(idx)
    if not data or 'rules' not in data or idx >= len(data['rules']):
        print('ERROR: Invalid index')
        return
    data['rules'].pop(idx)
    save_json(ROUTE_FILE, data)

def set_route_strategy(strategy):
    data = load_json(ROUTE_FILE)
    if not data:
        data = {'domainStrategy': strategy, 'rules': []}
    valid = ('AsIs', 'IPIfNonMatch', 'IPOnDemand')
    if strategy not in valid:
        print(f'ERROR: Invalid strategy. Must be one of: {", ".join(valid)}')
        return
    data['domainStrategy'] = strategy
    save_json(ROUTE_FILE, data)
    print(f'OK: 路由域名策略已设置为 {strategy}')

# ========== Stream Settings Builder ==========

def _build_stream(kw):
    """Build streamSettings dict from kwargs. Returns None if no relevant keys set."""
    network = kw.get('network', '')
    security = kw.get('security', '')
    if not network and not security:
        return None
    ss = {}
    if network:
        ss['network'] = network
    if security:
        ss['security'] = security
    # TCP header (http)
    if network == 'tcp':
        hdr = kw.get('header_type', '')
        if hdr == 'http':
            ss['tcpSettings'] = {'header': {'type': 'http'}}
    elif network == 'ws':
        wss = {}
        if kw.get('path'):
            wss['path'] = kw['path']
        if kw.get('host'):
            wss['headers'] = {'Host': kw['host']}
        ss['wsSettings'] = wss
    elif network == 'grpc':
        gs = {}
        if kw.get('service_name') or kw.get('grpc_service'):
            gs['serviceName'] = kw.get('service_name') or kw.get('grpc_service')
        if kw.get('multi_mode') in ('true', '1', 'yes'):
            gs['multiMode'] = True
        ss['grpcSettings'] = gs
    elif network in ('h2', 'http'):
        hs = {}
        if kw.get('path'):
            hs['path'] = kw['path']
        if kw.get('host'):
            hs['host'] = _norm_list(kw['host'])
        ss['httpSettings'] = hs
    elif network in ('kcp', 'mkcp'):
        ks = {}
        if kw.get('header_type'):
            ks['header'] = {'type': kw['header_type']}
        if kw.get('seed'):
            ks['seed'] = kw['seed']
        ss['kcpSettings'] = ks
    elif network == 'quic':
        qs = {}
        if kw.get('quic_security'):
            qs['security'] = kw['quic_security']
        if kw.get('quic_key'):
            qs['key'] = kw['quic_key']
        if kw.get('header_type'):
            qs['header'] = {'type': kw['header_type']}
        ss['quicSettings'] = qs
    # TLS
    if security == 'tls':
        tls = {}
        if kw.get('sni') or kw.get('server_name'):
            tls['serverName'] = kw.get('sni') or kw.get('server_name')
        if kw.get('alpn'):
            tls['alpn'] = _norm_list(kw['alpn'])
        if kw.get('allow_insecure') in ('true', '1', 'yes'):
            tls['allowInsecure'] = True
        if kw.get('fingerprint'):
            tls['fingerprint'] = kw['fingerprint']
        ss['tlsSettings'] = tls
    elif security == 'reality':
        rs = {}
        if kw.get('sni') or kw.get('server_name'):
            rs['serverName'] = kw.get('sni') or kw.get('server_name')
        if kw.get('public_key'):
            rs['publicKey'] = kw['public_key']
        if kw.get('short_id'):
            rs['shortId'] = kw['short_id']
        if kw.get('fingerprint'):
            rs['fingerprint'] = kw['fingerprint']
        if kw.get('spider_x'):
            rs['spiderX'] = kw['spider_x']
        ss['realitySettings'] = rs
    return ss

# ========== Outbound Management ==========

def list_outbounds():
    data = load_json(OUTBOUND_FILE)
    if not data:
        print('NO_OUTBOUNDS')
        return
    for i, ob in enumerate(data):
        tag = ob.get('tag', 'N/A')
        proto = ob.get('protocol', 'N/A')
        settings = ob.get('settings', {}) or {}
        detail = ''
        try:
            if proto == 'freedom':
                ds = settings.get('domainStrategy', '')
                detail = f'strategy={ds}' if ds else 'direct'
            elif proto == 'blackhole':
                detail = 'block'
            elif proto == 'dns':
                detail = f"{settings.get('address','')}:{settings.get('port','')}"
            elif proto == 'loopback':
                detail = f"inbound={settings.get('inboundTag','')}"
            elif proto in ('socks', 'http', 'shadowsocks', 'trojan'):
                s = (settings.get('servers') or [{}])[0]
                detail = f"{s.get('address','?')}:{s.get('port','?')}"
            elif proto in ('vmess', 'vless'):
                s = (settings.get('vnext') or [{}])[0]
                detail = f"{s.get('address','?')}:{s.get('port','?')}"
            elif proto == 'wireguard':
                peers = settings.get('peers') or [{}]
                detail = peers[0].get('endpoint', '')
        except Exception:
            detail = ''
        net = ob.get('streamSettings', {}).get('network', '')
        sec = ob.get('streamSettings', {}).get('security', '')
        if net or sec:
            detail = f'{detail} [{net}/{sec}]' if detail else f'[{net}/{sec}]'
        print(f'{i}|{tag}|{proto}|{detail}')

def add_outbound(tag, protocol, address='', port=0, **kw):
    data = load_json(OUTBOUND_FILE) or []
    ob = {'tag': tag, 'protocol': protocol, 'settings': {}}
    p = protocol
    try:
        port_i = int(port) if port else 0
    except Exception:
        port_i = 0
    if p == 'freedom':
        if address:
            ob['settings']['domainStrategy'] = address
        if kw.get('redirect'):
            ob['settings']['redirect'] = kw['redirect']
    elif p == 'blackhole':
        if kw.get('response_type'):
            ob['settings'] = {'response': {'type': kw['response_type']}}
    elif p == 'dns':
        ob['settings'] = {
            'network': kw.get('dns_network', 'udp'),
            'address': address or '8.8.8.8',
            'port': port_i or 53,
        }
        if kw.get('non_ip_query'):
            ob['settings']['nonIPQuery'] = kw['non_ip_query']
    elif p == 'loopback':
        ob['settings'] = {'inboundTag': kw.get('inbound_tag', '')}
    elif p == 'http':
        srv = {'address': address, 'port': port_i}
        if kw.get('username'):
            srv['users'] = [{'user': kw.get('username',''), 'pass': kw.get('password','')}]
        ob['settings'] = {'servers': [srv]}
    elif p == 'socks':
        srv = {'address': address, 'port': port_i}
        if kw.get('username'):
            srv['users'] = [{'user': kw.get('username',''), 'pass': kw.get('password',''),
                             'level': int(kw.get('level', 0) or 0)}]
        ob['settings'] = {'servers': [srv]}
    elif p == 'shadowsocks':
        srv = {
            'address': address,
            'port': port_i,
            'method': kw.get('method', 'aes-128-gcm'),
            'password': kw.get('password', ''),
        }
        if kw.get('uot') in ('true', '1', 'yes'):
            srv['uot'] = True
        if kw.get('ivcheck') in ('true', '1', 'yes'):
            srv['ivCheck'] = True
        ob['settings'] = {'servers': [srv]}
    elif p == 'trojan':
        srv = {'address': address, 'port': port_i, 'password': kw.get('password', '')}
        if kw.get('email'):
            srv['email'] = kw['email']
        ob['settings'] = {'servers': [srv]}
    elif p == 'vmess':
        user = {
            'id': kw.get('uuid', ''),
            'alterId': int(kw.get('alter_id', 0) or 0),
            'security': kw.get('security_cipher', 'auto'),
        }
        if kw.get('level'):
            user['level'] = int(kw['level'])
        ob['settings'] = {'vnext': [{'address': address, 'port': port_i, 'users': [user]}]}
    elif p == 'vless':
        user = {
            'id': kw.get('uuid', ''),
            'encryption': kw.get('encryption', 'none'),
        }
        if kw.get('flow'):
            user['flow'] = kw['flow']
        if kw.get('level'):
            user['level'] = int(kw['level'])
        ob['settings'] = {'vnext': [{'address': address, 'port': port_i, 'users': [user]}]}
    elif p == 'wireguard':
        ob['settings'] = {
            'secretKey': kw.get('secret_key', kw.get('private_key', '')),
            'address': _norm_list(kw.get('local_addr', '10.0.0.2/32')),
            'peers': [{
                'publicKey': kw.get('public_key', ''),
                'preSharedKey': kw.get('preshared_key', ''),
                'endpoint': f"{address}:{port_i}",
                'allowedIPs': _norm_list(kw.get('allowed_ips', '0.0.0.0/0,::/0')),
                'keepAlive': int(kw.get('keep_alive', 0) or 0),
            }],
            'mtu': int(kw.get('mtu', 1420) or 1420),
        }
    else:
        print(f'ERROR: Unsupported outbound protocol: {p}')
        return
    ss = _build_stream(kw)
    if ss:
        ob['streamSettings'] = ss
    if kw.get('send_through'):
        ob['sendThrough'] = kw['send_through']
    data.append(ob)
    save_json(OUTBOUND_FILE, data)

def delete_outbound(idx):
    data = load_json(OUTBOUND_FILE)
    idx = int(idx)
    if not data or idx >= len(data):
        print('ERROR: Invalid index')
        return
    data.pop(idx)
    save_json(OUTBOUND_FILE, data)

def _extract_target(ob):
    """从 outbound/inbound 中提取 (address, port) 元组 (list)。"""
    settings = ob.get('settings', {}) or {}
    proto = ob.get('protocol', '')
    targets = []
    for k in ('servers', 'vnext', 'peers'):
        arr = settings.get(k) or []
        for s in arr:
            addr = s.get('address', '') or s.get('endpoint', '')
            port = s.get('port', 0)
            if k == 'peers' and 'endpoint' in s:
                ep = s['endpoint']
                if ':' in ep:
                    a, p = ep.rsplit(':', 1)
                    addr = a.strip('[]'); port = int(p) if p.isdigit() else 0
            if addr and port:
                targets.append((addr, int(port)))
    return targets

def _tcp_probe(host, port, timeout=5):
    """TCP 连通性探测, 返回 (ok, latency_ms, msg)"""
    import socket, time as _t
    # 解析地址
    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except Exception as e:
        return False, 0, f"DNS 解析失败: {e}"
    last_err = ""
    for family, socktype, proto, _cn, sa in infos:
        s = socket.socket(family, socktype, proto)
        s.settimeout(timeout)
        t0 = _t.time()
        try:
            s.connect(sa)
            latency = int((_t.time() - t0) * 1000)
            s.close()
            return True, latency, f"TCP 通 (via {sa[0]})"
        except Exception as e:
            last_err = str(e)
            try:
                s.close()
            except Exception:
                pass
    return False, 0, f"连接失败: {last_err}"

def test_outbound(idx):
    """测试指定出站的目标地址是否可达。"""
    data = load_json(OUTBOUND_FILE)
    if not data:
        print('NO_OUTBOUNDS')
        return
    if idx == 'all':
        indices = list(range(len(data)))
    else:
        try:
            indices = [int(x) for x in _norm_list(idx)]
        except Exception:
            print('ERROR: 无效序号')
            return
    for i in indices:
        if i < 0 or i >= len(data):
            print(f'{i}|invalid|-|-|序号超出范围')
            continue
        ob = data[i]
        proto = ob.get('protocol', '')
        tag = ob.get('tag', '')
        if proto in ('freedom', 'blackhole', 'dns', 'loopback'):
            print(f'{i}|skip|{tag}|{proto}|无需测试')
            continue
        targets = _extract_target(ob)
        if not targets:
            print(f'{i}|noaddr|{tag}|{proto}|未找到目标地址')
            continue
        for addr, port in targets:
            ok, latency, msg = _tcp_probe(addr, port, timeout=5)
            state = 'ok' if ok else 'fail'
            print(f'{i}|{state}|{tag}|{proto}|{addr}:{port} - {msg} ({latency}ms)')


# ========== Inbound Management ==========

def list_inbounds():
    data = load_json(INBOUND_FILE)
    if not data:
        print('NO_INBOUNDS')
        return
    for i, ib in enumerate(data):
        proto = ib.get('protocol', 'N/A')
        listen = ib.get('listen', '0.0.0.0')
        port = ib.get('port', 'N/A')
        tag = ib.get('tag', '')
        net = ib.get('streamSettings', {}).get('network', '')
        sec = ib.get('streamSettings', {}).get('security', '')
        extra = f' [{net}/{sec}]' if (net or sec) else ''
        print(f'{i}|{proto}|{listen}:{port}|{tag}{extra}')

def add_inbound(protocol, listen_addr, port, **kw):
    data = load_json(INBOUND_FILE) or []
    try:
        port_i = int(port)
    except Exception:
        print('ERROR: invalid port')
        return
    ib = {'listen': listen_addr, 'port': port_i, 'protocol': protocol, 'settings': {}}
    if kw.get('tag'):
        ib['tag'] = kw['tag']
    p = protocol
    if p == 'dokodemo-door':
        ib['settings'] = {
            'address': kw.get('target_addr', ''),
            'port': int(kw.get('target_port', 0) or 0),
            'network': kw.get('net', 'tcp,udp'),
            'followRedirect': kw.get('follow_redirect') in ('true', '1', 'yes'),
        }
    elif p == 'http':
        s = {'timeout': int(kw.get('timeout', 300) or 300),
             'allowTransparent': kw.get('allow_transparent') in ('true','1','yes')}
        if kw.get('username'):
            s['accounts'] = [{'user': kw.get('username',''), 'pass': kw.get('password','')}]
        ib['settings'] = s
    elif p == 'socks':
        s = {
            'auth': kw.get('auth', 'noauth'),
            'udp': kw.get('udp') in ('true','1','yes'),
            'ip': kw.get('bind_ip', '127.0.0.1'),
        }
        if s['auth'] == 'password' and kw.get('username'):
            s['accounts'] = [{'user': kw.get('username',''), 'pass': kw.get('password','')}]
        ib['settings'] = s
    elif p == 'shadowsocks':
        ib['settings'] = {
            'method': kw.get('method', 'aes-128-gcm'),
            'password': kw.get('password', ''),
            'network': kw.get('net', 'tcp,udp'),
            'ivCheck': kw.get('ivcheck') in ('true','1','yes'),
        }
    elif p == 'vmess':
        client = {'id': kw.get('uuid',''), 'alterId': int(kw.get('alter_id',0) or 0)}
        if kw.get('email'):
            client['email'] = kw['email']
        if kw.get('level'):
            client['level'] = int(kw['level'])
        ib['settings'] = {'clients': [client], 'default': {'level': 0, 'alterId': 0}}
    elif p == 'vless':
        client = {'id': kw.get('uuid','')}
        if kw.get('flow'):
            client['flow'] = kw['flow']
        if kw.get('email'):
            client['email'] = kw['email']
        if kw.get('level'):
            client['level'] = int(kw['level'])
        ib['settings'] = {
            'clients': [client],
            'decryption': kw.get('decryption','none'),
        }
        if kw.get('fallback_dest'):
            ib['settings']['fallbacks'] = [{'dest': kw['fallback_dest']}]
    elif p == 'trojan':
        client = {'password': kw.get('password','')}
        if kw.get('email'):
            client['email'] = kw['email']
        if kw.get('level'):
            client['level'] = int(kw['level'])
        if kw.get('flow'):
            client['flow'] = kw['flow']
        ib['settings'] = {'clients': [client]}
        if kw.get('fallback_dest'):
            ib['settings']['fallbacks'] = [{'dest': kw['fallback_dest']}]
    else:
        print(f'ERROR: Unsupported inbound protocol: {p}')
        return
    ss = _build_stream(kw)
    if ss:
        ib['streamSettings'] = ss
    if kw.get('sniffing') in ('true','1','yes'):
        ib['sniffing'] = {
            'enabled': True,
            'destOverride': _norm_list(kw.get('sniff_dest', 'http,tls')),
        }
    data.append(ib)
    save_json(INBOUND_FILE, data)

def delete_inbound(idx):
    data = load_json(INBOUND_FILE)
    idx = int(idx)
    if not data or idx >= len(data):
        print('ERROR: Invalid index')
        return
    data.pop(idx)
    save_json(INBOUND_FILE, data)

def test_inbound(idx):
    """测试指定入站端口是否在监听。"""
    data = load_json(INBOUND_FILE)
    if not data:
        print('NO_INBOUNDS')
        return
    if idx == 'all':
        indices = list(range(len(data)))
    else:
        try:
            indices = [int(x) for x in _norm_list(idx)]
        except Exception:
            print('ERROR: 无效序号')
            return
    for i in indices:
        if i < 0 or i >= len(data):
            print(f'{i}|invalid|-|-|序号超出范围')
            continue
        ib = data[i]
        proto = ib.get('protocol', '')
        listen = ib.get('listen', '0.0.0.0')
        port = ib.get('port', 0)
        probe_host = '127.0.0.1' if listen in ('0.0.0.0', '::') else listen
        ok, latency, msg = _tcp_probe(probe_host, port, timeout=3)
        state = 'ok' if ok else 'fail'
        print(f'{i}|{state}|{proto}|{listen}:{port}|{msg} ({latency}ms)')


# ========== DNS Management ==========

def show_dns():
    data = load_json(DNS_FILE)
    if not data:
        print('NO_DNS_CONFIG')
        return
    print(json.dumps(data, indent=2, ensure_ascii=False))

def set_dns_servers(servers_str):
    data = load_json(DNS_FILE)
    if not data:
        data = {}
    data['servers'] = _norm_list(servers_str)
    if 'tag' not in data:
        data['tag'] = 'dns_inbound'
    save_json(DNS_FILE, data)

# ========== Global Config ==========

def show_global():
    cfg = load_config()
    if not cfg:
        print('NO_CONFIG')
        return
    log = cfg.get('Log', {})
    conn = cfg.get('ConnectionConfig', {})
    print(f"LogLevel={log.get('Level', 'N/A')}")
    print(f"DnsConfigPath={cfg.get('DnsConfigPath', '')}")
    print(f"RouteConfigPath={cfg.get('RouteConfigPath', '')}")
    print(f"InboundConfigPath={cfg.get('InboundConfigPath', '')}")
    print(f"OutboundConfigPath={cfg.get('OutboundConfigPath', '')}")
    print(f"ConnIdle={conn.get('ConnIdle', 30)}")
    print(f"BufferSize={conn.get('BufferSize', 64)}")
    print(f"NodeCount={len(cfg.get('Nodes', []))}")

def set_global(field, value):
    cfg = load_config()
    if not cfg:
        print('ERROR: No config')
        return
    if field == 'LogLevel':
        if 'Log' not in cfg: cfg['Log'] = {}
        cfg['Log']['Level'] = value
    elif field == 'DnsConfigPath':
        cfg['DnsConfigPath'] = value if value != 'none' else ''
    elif field == 'RouteConfigPath':
        cfg['RouteConfigPath'] = value if value != 'none' else ''
    elif field == 'InboundConfigPath':
        cfg['InboundConfigPath'] = value if value != 'none' else ''
    elif field == 'OutboundConfigPath':
        cfg['OutboundConfigPath'] = value if value != 'none' else ''
    elif field == 'ConnIdle':
        if 'ConnectionConfig' not in cfg: cfg['ConnectionConfig'] = {}
        cfg['ConnectionConfig']['ConnIdle'] = int(value)
    elif field == 'BufferSize':
        if 'ConnectionConfig' not in cfg: cfg['ConnectionConfig'] = {}
        cfg['ConnectionConfig']['BufferSize'] = int(value)
    else:
        print(f'ERROR: Unknown field {field}')
        return
    save_config(cfg)
    print(f'OK: {field} = {value}')

# ========== Link Import ==========

# ========== 入站 Socket 调优 ==========

_SOCKOPT_FIELDS = [
    # (命令行参数名, 配置键名, 类型)
    ('tcp_fast_open',      'TCPFastOpen',            'bool'),
    ('queue_length',       'TCPFastOpenQueueLength', 'int'),
    ('keepalive_idle',     'TCPKeepAliveIdle',       'int'),
    ('keepalive_interval', 'TCPKeepAliveInterval',   'int'),
    ('user_timeout',       'TCPUserTimeout',         'int'),
    ('congestion',         'TCPCongestion',          'str'),
    ('mptcp',              'TCPMptcp',               'bool'),
    ('window_clamp',       'TCPWindowClamp',         'int'),
    ('max_seg',            'TCPMaxSeg',              'int'),
    ('bind_interface',     'Interface',              'str'),
]


def _parse_bool(v):
    s = str(v).strip().lower()
    if s in ('true', '1', 'yes', 'y', 'on', '是', '开', '开启'):
        return True
    if s in ('false', '0', 'no', 'n', 'off', '否', '关', '关闭'):
        return False
    raise ValueError(f'无法识别的布尔值: {v}')


def _parse_sockopt_argv(argv):
    """把 --tcp-fast-open true --queue-length 4096 这类参数解析成配置字典。"""
    alias = {name.replace('_', '-'): (name, key, typ)
             for name, key, typ in _SOCKOPT_FIELDS}
    out = {}
    i = 0
    while i < len(argv):
        tok = argv[i]
        if not tok.startswith('--'):
            i += 1
            continue
        flag = tok[2:]
        if flag not in alias:
            raise ValueError(f'未知参数: {tok}')
        if i + 1 >= len(argv):
            raise ValueError(f'{tok} 缺少取值')
        raw = argv[i + 1]
        _, key, typ = alias[flag]
        if typ == 'bool':
            out[key] = _parse_bool(raw)
        elif typ == 'int':
            out[key] = int(raw)
        else:
            out[key] = raw
        i += 2
    return out


def sockopt_set(argv):
    """为所有节点的 ControllerConfig 写入/更新 SocketConfig。"""
    updates = _parse_sockopt_argv(argv)
    if not updates:
        print('ERROR: 未提供任何可设置项')
        return

    cfg = load_config()
    if not cfg:
        print('ERROR: No config')
        return
    nodes = cfg.get('Nodes') or []
    if not nodes:
        print('ERROR: 配置中没有任何节点')
        return

    for node in nodes:
        cc = node.setdefault('ControllerConfig', {})
        sc = cc.get('SocketConfig')
        if not isinstance(sc, dict):
            sc = {}
        for k, v in updates.items():
            # 取值为 0 / 空字符串视为「不设置」，直接移除该键，
            # 避免把无意义的 0 写进配置造成误解。
            if (isinstance(v, int) and not isinstance(v, bool) and v == 0) or v == '':
                sc.pop(k, None)
            else:
                sc[k] = v
        if sc:
            cc['SocketConfig'] = sc
        else:
            cc.pop('SocketConfig', None)

    save_config(cfg)
    shown = ', '.join(f'{k}={v}' for k, v in updates.items())
    print(f'OK: 已为 {len(nodes)} 个节点设置 SocketConfig ({shown})')


def sockopt_remove():
    """移除所有节点的 SocketConfig，回到 XrayR 默认行为。"""
    cfg = load_config()
    if not cfg:
        print('ERROR: No config')
        return
    nodes = cfg.get('Nodes') or []
    removed = 0
    for node in nodes:
        cc = node.get('ControllerConfig')
        if isinstance(cc, dict) and cc.pop('SocketConfig', None) is not None:
            removed += 1
    save_config(cfg)
    print(f'OK: 已从 {removed} 个节点移除 SocketConfig')


def sockopt_show():
    """以表格展示各节点当前的 SocketConfig。"""
    cfg = load_config()
    if not cfg:
        print('ERROR: No config')
        return
    nodes = cfg.get('Nodes') or []
    if not nodes:
        print('（无节点）')
        return
    label = {
        'TCPFastOpen': 'TCP Fast Open',
        'TCPFastOpenQueueLength': 'TFO 队列长度',
        'TCPKeepAliveIdle': 'keepalive 空闲(秒)',
        'TCPKeepAliveInterval': 'keepalive 间隔(秒)',
        'TCPUserTimeout': '未确认数据超时(毫秒)',
        'TCPCongestion': '拥塞算法',
        'TCPMptcp': 'Multipath TCP',
        'TCPWindowClamp': '窗口上限(字节)',
        'TCPMaxSeg': '最大段长(字节)',
        'Interface': '绑定网卡',
    }
    for idx, node in enumerate(nodes, 1):
        api = node.get('ApiConfig') or {}
        cc = node.get('ControllerConfig') or {}
        sc = cc.get('SocketConfig')
        title = f"节点 {idx}  (ID={api.get('NodeID', '?')}, 类型={api.get('NodeType', '?')})"
        print(title)
        if not isinstance(sc, dict) or not sc:
            print('  未配置 SocketConfig（保持默认行为）')
            print('')
            continue
        for k, v in sc.items():
            name = label.get(k, k)
            if isinstance(v, bool):
                v = '开启' if v else '关闭'
            print(f'  {name}: {v}')
        print('')

import base64
import re
try:
    from urllib.parse import urlparse, parse_qs, unquote
except ImportError:
    from urlparse import urlparse, parse_qs
    from urllib import unquote

def _b64decode(s):
    """Decode base64 with padding fix."""
    s = s.strip()
    pad = 4 - len(s) % 4
    if pad != 4:
        s += '=' * pad
    return base64.urlsafe_b64decode(s).decode('utf-8', errors='replace')

def _parse_vmess(uri):
    """Parse vmess://BASE64 → outbound dict."""
    raw = uri[len('vmess://'):]
    j = json.loads(_b64decode(raw))
    tag = j.get('ps', '') or f"vmess-{j.get('add','')}"
    address = j.get('add', '')
    port = int(j.get('port', 0) or 0)
    ob = {
        'tag': tag,
        'protocol': 'vmess',
        'settings': {
            'vnext': [{
                'address': address,
                'port': port,
                'users': [{
                    'id': j.get('id', ''),
                    'alterId': int(j.get('aid', 0) or 0),
                    'security': j.get('scy', 'auto') or 'auto',
                }]
            }]
        }
    }
    net = j.get('net', '')
    tls = j.get('tls', '')
    kw = {}
    if net:
        kw['network'] = net
    if tls:
        kw['security'] = tls
    if j.get('sni'):
        kw['sni'] = j['sni']
    if j.get('alpn'):
        kw['alpn'] = j['alpn']
    if j.get('fp'):
        kw['fingerprint'] = j['fp']
    # Transport specifics
    if net == 'ws':
        kw['path'] = j.get('path', '/')
        if j.get('host'):
            kw['host'] = j['host']
    elif net == 'grpc':
        if j.get('path'):
            kw['service_name'] = j['path']
    elif net in ('h2', 'http'):
        kw['path'] = j.get('path', '/')
        if j.get('host'):
            kw['host'] = j['host']
    elif net == 'tcp' and j.get('type') == 'http':
        kw['header_type'] = 'http'
    elif net in ('kcp', 'mkcp'):
        if j.get('type'):
            kw['header_type'] = j['type']
        if j.get('path'):
            kw['seed'] = j['path']
    ss = _build_stream(kw)
    if ss:
        ob['streamSettings'] = ss
    return ob

def _parse_vless(uri):
    """Parse vless://UUID@host:port?params#remark."""
    body = uri[len('vless://'):]
    remark = ''
    if '#' in body:
        body, remark = body.rsplit('#', 1)
        remark = unquote(remark)
    parsed = urlparse('vless://' + body)
    uuid = parsed.username or ''
    address = parsed.hostname or ''
    port = int(parsed.port or 0)
    params = parse_qs(parsed.query)
    def p(k): return params.get(k, [''])[0]
    tag = remark or f"vless-{address}"
    ob = {
        'tag': tag,
        'protocol': 'vless',
        'settings': {
            'vnext': [{
                'address': address,
                'port': port,
                'users': [{
                    'id': uuid,
                    'encryption': p('encryption') or 'none',
                }]
            }]
        }
    }
    flow = p('flow')
    if flow:
        ob['settings']['vnext'][0]['users'][0]['flow'] = flow
    kw = {}
    net = p('type') or p('net') or 'tcp'
    kw['network'] = net
    sec = p('security') or 'none'
    if sec and sec != 'none':
        kw['security'] = sec
    if p('sni') or p('serverName'):
        kw['sni'] = p('sni') or p('serverName')
    if p('alpn'):
        kw['alpn'] = unquote(p('alpn'))
    if p('fp'):
        kw['fingerprint'] = p('fp')
    # Transport
    if net == 'ws':
        kw['path'] = p('path') or '/'
        if p('host'):
            kw['host'] = p('host')
    elif net == 'grpc':
        if p('serviceName') or p('path'):
            kw['service_name'] = p('serviceName') or p('path')
        if p('mode') == 'multi':
            kw['multi_mode'] = 'true'
    elif net in ('h2', 'http'):
        kw['path'] = p('path') or '/'
        if p('host'):
            kw['host'] = p('host')
    elif net in ('kcp', 'mkcp'):
        if p('headerType'):
            kw['header_type'] = p('headerType')
        if p('seed'):
            kw['seed'] = p('seed')
    elif net == 'tcp':
        if p('headerType') == 'http':
            kw['header_type'] = 'http'
    # Reality
    if sec == 'reality':
        if p('pbk'):
            kw['public_key'] = p('pbk')
        if p('sid'):
            kw['short_id'] = p('sid')
        if p('spx'):
            kw['spider_x'] = unquote(p('spx'))
    ss = _build_stream(kw)
    if ss:
        ob['streamSettings'] = ss
    return ob

def _parse_trojan(uri):
    """Parse trojan://password@host:port?params#remark."""
    body = uri[len('trojan://'):]
    remark = ''
    if '#' in body:
        body, remark = body.rsplit('#', 1)
        remark = unquote(remark)
    parsed = urlparse('trojan://' + body)
    password = unquote(parsed.username or '')
    address = parsed.hostname or ''
    port = int(parsed.port or 443)
    params = parse_qs(parsed.query)
    def p(k): return params.get(k, [''])[0]
    tag = remark or f"trojan-{address}"
    ob = {
        'tag': tag,
        'protocol': 'trojan',
        'settings': {
            'servers': [{
                'address': address,
                'port': port,
                'password': password,
            }]
        }
    }
    kw = {}
    net = p('type') or p('net') or 'tcp'
    kw['network'] = net
    sec = p('security') or 'tls'
    if sec and sec != 'none':
        kw['security'] = sec
    if p('sni') or p('serverName'):
        kw['sni'] = p('sni') or p('serverName')
    if p('alpn'):
        kw['alpn'] = unquote(p('alpn'))
    if p('fp'):
        kw['fingerprint'] = p('fp')
    if net == 'ws':
        kw['path'] = p('path') or '/'
        if p('host'):
            kw['host'] = p('host')
    elif net == 'grpc':
        if p('serviceName') or p('path'):
            kw['service_name'] = p('serviceName') or p('path')
    elif net in ('h2', 'http'):
        kw['path'] = p('path') or '/'
        if p('host'):
            kw['host'] = p('host')
    if sec == 'reality':
        if p('pbk'):
            kw['public_key'] = p('pbk')
        if p('sid'):
            kw['short_id'] = p('sid')
        if p('spx'):
            kw['spider_x'] = unquote(p('spx'))
    ss = _build_stream(kw)
    if ss:
        ob['streamSettings'] = ss
    return ob

def _parse_ss(uri):
    """Parse ss://BASE64(method:password)@host:port#remark or SIP002."""
    body = uri[len('ss://'):]
    remark = ''
    if '#' in body:
        body, remark = body.rsplit('#', 1)
        remark = unquote(remark)
    # SIP002: ss://base64(method:password)@host:port or ss://method:password@host:port
    # Also: ss://BASE64-everything
    if '@' in body:
        userinfo, hostport = body.rsplit('@', 1)
        try:
            userinfo = _b64decode(userinfo)
        except Exception:
            pass
        if ':' not in userinfo:
            # All-in-one base64
            try:
                decoded = _b64decode(body)
                if '@' in decoded:
                    return _parse_ss('ss://' + decoded + ('#' + remark if remark else ''))
            except Exception:
                pass
            print('ERROR: Cannot parse SS link')
            return None
        method, password = userinfo.split(':', 1)
        # hostport might have params
        if '?' in hostport:
            hostport = hostport.split('?')[0]
        if ':' in hostport:
            host, port_s = hostport.rsplit(':', 1)
            host = host.strip('[]')
            port = int(port_s)
        else:
            host = hostport
            port = 0
    else:
        # Legacy all-base64
        try:
            decoded = _b64decode(body)
        except Exception:
            print('ERROR: Cannot decode SS link')
            return None
        return _parse_ss('ss://' + decoded + ('#' + remark if remark else ''))
    tag = remark or f"ss-{host}"
    ob = {
        'tag': tag,
        'protocol': 'shadowsocks',
        'settings': {
            'servers': [{
                'address': host,
                'port': port,
                'method': method,
                'password': password,
            }]
        }
    }
    return ob

def _parse_hysteria2(uri):
    """Parse hysteria2://password@host:port?params#remark (for reference/storage)."""
    body = uri.split('://', 1)[1]
    remark = ''
    if '#' in body:
        body, remark = body.rsplit('#', 1)
        remark = unquote(remark)
    parsed = urlparse('hy2://' + body)
    password = unquote(parsed.username or '')
    address = parsed.hostname or ''
    port = int(parsed.port or 443)
    params = parse_qs(parsed.query)
    def p(k): return params.get(k, [''])[0]
    tag = remark or f"hy2-{address}"
    # Store as raw JSON since xray-core doesn't natively support hy2
    ob = {
        'tag': tag,
        'protocol': 'hysteria2',
        'settings': {
            'servers': [{
                'address': address,
                'port': port,
                'password': password,
            }]
        }
    }
    if p('sni'):
        ob['streamSettings'] = {'security': 'tls', 'tlsSettings': {'serverName': p('sni')}}
    if p('obfs'):
        ob.setdefault('settings', {})['obfs'] = p('obfs')
        ob['settings']['obfsPassword'] = p('obfs-password') or p('obfsPassword') or ''
    if p('insecure') in ('1', 'true'):
        ob.setdefault('streamSettings', {}).setdefault('tlsSettings', {})['allowInsecure'] = True
    return ob

def import_link(link_str):
    """Parse one or more share links (newline/space separated) and add as outbounds."""
    links = re.split(r'[\n\r\s]+', link_str.strip())
    data = load_json(OUTBOUND_FILE) or []
    count = 0
    for link in links:
        link = link.strip()
        if not link:
            continue
        ob = None
        try:
            if link.startswith('vmess://'):
                ob = _parse_vmess(link)
            elif link.startswith('vless://'):
                ob = _parse_vless(link)
            elif link.startswith('trojan://'):
                ob = _parse_trojan(link)
            elif link.startswith('ss://'):
                ob = _parse_ss(link)
            elif link.startswith('hysteria2://') or link.startswith('hy2://'):
                ob = _parse_hysteria2(link)
            else:
                print(f'WARN: 不支持的链接格式: {link[:30]}...')
                continue
        except Exception as e:
            print(f'ERROR: 解析失败 [{link[:30]}...]: {e}')
            continue
        if ob:
            data.append(ob)
            count += 1
            print(f'  + [{ob["protocol"]}] {ob["tag"]}')
    if count > 0:
        save_json(OUTBOUND_FILE, data)
        print(f'OK: 成功导入 {count} 个出站')
    else:
        print('WARN: 未成功导入任何节点')

def export_links():
    """Export all outbounds as share links."""
    data = load_json(OUTBOUND_FILE)
    if not data:
        print('NO_OUTBOUNDS')
        return
    for ob in data:
        proto = ob.get('protocol', '')
        link = _export_one(ob)
        if link:
            print(link)
        else:
            print(f'# [{proto}] {ob.get("tag","")} (不支持导出)')

def _export_one(ob):
    proto = ob.get('protocol', '')
    tag = ob.get('tag', '')
    settings = ob.get('settings', {}) or {}
    ss_raw = ob.get('streamSettings', {}) or {}
    if proto == 'vmess':
        vnext = (settings.get('vnext') or [{}])[0]
        users = (vnext.get('users') or [{}])[0]
        j = {
            'v': '2',
            'ps': tag,
            'add': vnext.get('address', ''),
            'port': str(vnext.get('port', '')),
            'id': users.get('id', ''),
            'aid': str(users.get('alterId', 0)),
            'scy': users.get('security', 'auto'),
            'net': ss_raw.get('network', 'tcp'),
            'type': 'none',
            'host': '',
            'path': '',
            'tls': ss_raw.get('security', ''),
            'sni': '',
            'alpn': '',
            'fp': '',
        }
        net = j['net']
        if net == 'ws':
            ws = ss_raw.get('wsSettings', {})
            j['path'] = ws.get('path', '/')
            j['host'] = (ws.get('headers') or {}).get('Host', '')
        elif net == 'grpc':
            gs = ss_raw.get('grpcSettings', {})
            j['path'] = gs.get('serviceName', '')
        elif net in ('h2', 'http'):
            hs = ss_raw.get('httpSettings', {})
            j['path'] = hs.get('path', '/')
            j['host'] = ','.join(hs.get('host', []))
        elif net in ('kcp', 'mkcp'):
            ks = ss_raw.get('kcpSettings', {})
            j['type'] = (ks.get('header') or {}).get('type', 'none')
            j['path'] = ks.get('seed', '')
        elif net == 'tcp':
            ts = ss_raw.get('tcpSettings', {})
            if (ts.get('header') or {}).get('type') == 'http':
                j['type'] = 'http'
        if ss_raw.get('security') == 'tls':
            tls = ss_raw.get('tlsSettings', {})
            j['sni'] = tls.get('serverName', '')
            j['alpn'] = ','.join(tls.get('alpn', []))
            j['fp'] = tls.get('fingerprint', '')
        encoded = base64.urlsafe_b64encode(json.dumps(j, ensure_ascii=False).encode()).decode().rstrip('=')
        return f'vmess://{encoded}'
    elif proto == 'vless':
        vnext = (settings.get('vnext') or [{}])[0]
        users = (vnext.get('users') or [{}])[0]
        uuid = users.get('id', '')
        addr = vnext.get('address', '')
        port = vnext.get('port', '')
        params = []
        net = ss_raw.get('network', 'tcp')
        params.append(f'type={net}')
        sec = ss_raw.get('security', 'none')
        params.append(f'security={sec}')
        if users.get('flow'):
            params.append(f'flow={users["flow"]}')
        if net == 'ws':
            ws = ss_raw.get('wsSettings', {})
            params.append(f'path={unquote(ws.get("path","/"))}')
            h = (ws.get('headers') or {}).get('Host', '')
            if h: params.append(f'host={h}')
        elif net == 'grpc':
            gs = ss_raw.get('grpcSettings', {})
            if gs.get('serviceName'):
                params.append(f'serviceName={gs["serviceName"]}')
        if sec == 'tls':
            tls = ss_raw.get('tlsSettings', {})
            if tls.get('serverName'): params.append(f'sni={tls["serverName"]}')
            if tls.get('fingerprint'): params.append(f'fp={tls["fingerprint"]}')
            if tls.get('alpn'): params.append(f'alpn={",".join(tls["alpn"])}')
        elif sec == 'reality':
            rs = ss_raw.get('realitySettings', {})
            if rs.get('serverName'): params.append(f'sni={rs["serverName"]}')
            if rs.get('publicKey'): params.append(f'pbk={rs["publicKey"]}')
            if rs.get('shortId'): params.append(f'sid={rs["shortId"]}')
            if rs.get('fingerprint'): params.append(f'fp={rs["fingerprint"]}')
            if rs.get('spiderX'): params.append(f'spx={rs["spiderX"]}')
        from urllib.parse import quote
        return f'vless://{uuid}@{addr}:{port}?{"&".join(params)}#{quote(tag)}'
    elif proto == 'trojan':
        srv = (settings.get('servers') or [{}])[0]
        pw = srv.get('password', '')
        addr = srv.get('address', '')
        port = srv.get('port', 443)
        params = []
        net = ss_raw.get('network', 'tcp')
        params.append(f'type={net}')
        sec = ss_raw.get('security', 'tls')
        params.append(f'security={sec}')
        if sec == 'tls':
            tls = ss_raw.get('tlsSettings', {})
            if tls.get('serverName'): params.append(f'sni={tls["serverName"]}')
            if tls.get('fingerprint'): params.append(f'fp={tls["fingerprint"]}')
        elif sec == 'reality':
            rs = ss_raw.get('realitySettings', {})
            if rs.get('serverName'): params.append(f'sni={rs["serverName"]}')
            if rs.get('publicKey'): params.append(f'pbk={rs["publicKey"]}')
            if rs.get('shortId'): params.append(f'sid={rs["shortId"]}')
            if rs.get('fingerprint'): params.append(f'fp={rs["fingerprint"]}')
        if net == 'ws':
            ws = ss_raw.get('wsSettings', {})
            params.append(f'path={ws.get("path","/")}')
            h = (ws.get('headers') or {}).get('Host', '')
            if h: params.append(f'host={h}')
        elif net == 'grpc':
            gs = ss_raw.get('grpcSettings', {})
            if gs.get('serviceName'):
                params.append(f'serviceName={gs["serviceName"]}')
        from urllib.parse import quote
        return f'trojan://{quote(pw)}@{addr}:{port}?{"&".join(params)}#{quote(tag)}'
    elif proto == 'shadowsocks':
        srv = (settings.get('servers') or [{}])[0]
        method = srv.get('method', '')
        pw = srv.get('password', '')
        addr = srv.get('address', '')
        port = srv.get('port', 0)
        userinfo = base64.urlsafe_b64encode(f'{method}:{pw}'.encode()).decode().rstrip('=')
        from urllib.parse import quote
        return f'ss://{userinfo}@{addr}:{port}#{quote(tag)}'
    return None

# ========== Main ==========

def main():
    if len(sys.argv) < 2:
        print('Usage: config_helper.py <command> [args...]')
        sys.exit(1)

    cmd = sys.argv[1]
    raw = sys.argv[2:]
    # Separate positional and key=value pairs
    args = []
    kwargs = {}
    for a in raw:
        if '=' in a and not a.startswith('='):
            k, v = a.split('=', 1)
            # Only treat as kwarg if key looks like an identifier
            if k.replace('_', '').replace('-', '').isalnum():
                kwargs[k.replace('-', '_')] = v
                continue
        args.append(a)

    commands = {
        'list-nodes': lambda: list_nodes(),
        'show-node': lambda: show_node(args[0]),
        'add-node': lambda: add_node(*args[:5]),
        'delete-node': lambda: delete_node(args[0]),
        'get-node-fields': lambda: get_node_fields(args[0]),
        'modify-node': lambda: modify_node(args[0], args[1], args[2]),
        'enable-node': lambda: enable_node(args[0]),
        'disable-node': lambda: disable_node(args[0]),
        'check-nodes': lambda: check_nodes(),
        'list-routes': lambda: list_routes(),
        'add-route': lambda: add_route_rule(args[0], args[1], args[2]),
        'delete-route': lambda: delete_route_rule(args[0]),
        'set-route-strategy': lambda: set_route_strategy(args[0]),
        'list-outbounds': lambda: list_outbounds(),
        'add-outbound': lambda: add_outbound(
            args[0], args[1],
            args[2] if len(args) > 2 else '',
            args[3] if len(args) > 3 else 0,
            **kwargs),
        'delete-outbound': lambda: delete_outbound(args[0]),
        'test-outbound': lambda: test_outbound(args[0] if args else 'all'),
        'list-inbounds': lambda: list_inbounds(),
        'add-inbound': lambda: add_inbound(args[0], args[1], args[2], **kwargs),
        'delete-inbound': lambda: delete_inbound(args[0]),
        'test-inbound': lambda: test_inbound(args[0] if args else 'all'),
        'show-dns': lambda: show_dns(),
        'set-dns': lambda: set_dns_servers(args[0]),
        'import-link': lambda: import_link(' '.join(args)),
        'export-links': lambda: export_links(),
        'show-global': lambda: show_global(),
        'set-global': lambda: set_global(args[0], args[1]),
        'sockopt-set': lambda: sockopt_set(raw),
        'sockopt-remove': lambda: sockopt_remove(),
        'sockopt-show': lambda: sockopt_show(),
    }

    if cmd in commands:
        try:
            commands[cmd]()
        except Exception as e:
            print(f'ERROR: {e}')
            sys.exit(1)
    else:
        print(f'ERROR: Unknown command: {cmd}')
        sys.exit(1)

if __name__ == '__main__':
    main()
