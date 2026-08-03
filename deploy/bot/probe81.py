#!/usr/bin/env python3
"""PrivDNS Gateway — :81 探测端点 (Android/iOS 公共)。

两个用途, 优先级有先后:

  1. **iOS OnDemand 探测**(原有, 不可破坏): 监听 0.0.0.0:81, GET 返回 HTTP 200
     (iOS URLStringProbe 要求 200 才算探测成功)。配合 nftables 只放行「内网卡来源
     段」→ :81: 普通卡探不通(被 drop)、内网卡探得通 → iOS OnDemand 据此只在内网卡
     (蜂窝)激活 DoT, 实现双卡区分。

  2. **链路诊断会话**(6.1B 新增): `GET /probe?t=<token>` 消费一次性 token, 证明
     手机的网络确实能到达网关的 :81。

第 1 条是硬约束: **任何情况下 GET 都必须返回 200** —— 路径不认识、参数不合法、
token 过期、状态文件写不下去, 全都照样 200。会话功能出问题只降级会话本身, 绝不能
让 iOS 的 OnDemand 判定探测失败。

隐私: log_message 保持静音; 不记录 URL、查询串、Cookie、请求体、User-Agent;
来源只取内核 peer 地址(client_address), **不读也不信任 X-Forwarded-For**。
"""
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import linksess
except ImportError:                                  # 会话模块缺失 → 退化成纯探测
    linksess = None


class H(BaseHTTPRequestHandler):
    server_version = "pdg-probe81"
    sys_version = ""

    def _200(self, body=b"ok"):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _maybe_session(self):
        """只在精确路径 /probe 且恰好一个合法 t 参数时才尝试消费。

        回给客户端的是**固定的几种**文案, 不回显任何输入 —— 回显等于把 token 或
        路径原样写到对端看得见的地方。返回 None 表示"这不是会话请求", 走普通 200。
        """
        if linksess is None:
            return None
        parts = urlsplit(self.path)
        if parts.path != "/probe":                   # 只认精确路径
            return None
        q = parse_qs(parts.query, keep_blank_values=True)
        if set(q) != {"t"} or len(q["t"]) != 1:      # 只认恰好一个 t 参数
            return None
        token = q["t"][0]
        if not linksess.TOKEN_RE.match(token):       # 形状不对就别去碰状态
            return None
        try:
            accepted, reason, _rec = linksess.consume(token, self.client_address[0])
        except Exception:                            # noqa: BLE001 —— 会话崩了也要 200
            return b"probe: session unavailable\n"
        if accepted:
            return b"probe: ok\n"
        return {
            linksess.R_SESSION_EXPIRED: b"probe: session expired\n",
            linksess.R_TOKEN_REUSED: b"probe: token already used\n",
            linksess.R_RATE_LIMITED: b"probe: too many attempts\n",
        }.get(reason, b"probe: not accepted\n")

    def do_GET(self):
        body = None
        try:
            body = self._maybe_session()
        except Exception:                            # noqa: BLE001
            body = None
        self._200(body if body is not None else b"ok")

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *a):                       # 静音: 不留访问日志
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 81), H).serve_forever()
