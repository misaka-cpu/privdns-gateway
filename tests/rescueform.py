#!/usr/bin/env python3
"""救援页的表单客户端(测试辅助) —— **按页面原样提交**, 不手写猜字段。

为什么要这么一层: 上一轮实机验收连撞三次 401→404→400, 全是客户端自己拼 URL 与字段拼错的:
  · 401 —— 登录之后又重启了 service, 会话在内存里, 一停就没了;
  · 404 —— 字段名写成 `snap`, 后端读的是 `snapshot`, 空值当然不在快照索引里;
  · 400 —— 确认页上有个 `confirm=yes` 复选框, 客户端压根没提交。
三次都不是产品问题, 而"照着记忆拼表单"这件事本身就是错的。所以这里改成解析真实 HTML:
form 的 action/method 与全部 input 都从页面读, 提交时原样带上。字段改了名、少了一项,
客户端会明确失败, 而不是发一个后端看不懂的请求再去猜哪一步错了。

TLS 走**证书固定**: 期望指纹由调用方从独立渠道取(SSH 上跑 `pdg rescue fingerprint`),
不是从这条连接自己拿的 —— 那样等于自己给自己作证。不用 verify=False 冒充校验。
凭据、cookie、nonce、digest 一律只记前若干位, 不落全值。
"""
import hashlib
import http.client
import re
import ssl
import urllib.parse
from html.parser import HTMLParser


class FormError(Exception):
    """页面上没有预期的表单/字段 —— 提交前就失败, 不去发一个注定被拒的请求。"""


class _Forms(HTMLParser):
    """把页面里的 form 抽成 (action, method, {name: value}, {checkbox names})。"""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.forms = []
        self._cur = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "form":
            self._cur = {"action": a.get("action", ""), "method": (a.get("method") or "get").lower(),
                         "fields": {}, "checkboxes": set()}
        elif tag == "input" and self._cur is not None:
            name = a.get("name")
            if not name:
                return
            typ = (a.get("type") or "text").lower()
            if typ == "checkbox":
                self._cur["checkboxes"].add(name)
                self._cur["fields"].setdefault(name, a.get("value", "on"))
            else:
                self._cur["fields"][name] = a.get("value", "")

    def handle_endtag(self, tag):
        if tag == "form" and self._cur is not None:
            self.forms.append(self._cur)
            self._cur = None


def parse_forms(html_text):
    p = _Forms()
    p.feed(html_text or "")
    return p.forms


def find_form(html_text, action_contains):
    for f in parse_forms(html_text):
        if action_contains in f["action"]:
            return f
    raise FormError("页面上没有 action 含 %r 的表单(字段改名/页面降级?)" % action_contains)


def fp_of(der):
    h = hashlib.sha256(der).hexdigest().upper()
    return ":".join(h[i:i + 2] for i in range(0, len(h), 2))


class Client:
    """一个会话 = 一个 cookie jar + 一次证书固定。"""

    def __init__(self, host, port, expect_fp=None, timeout=180):
        self.host, self.port, self.timeout = host, int(port), timeout
        self.expect_fp = (expect_fp or "").strip().upper()
        self.jar = {}
        self.seen_fp = ""
        # 最近一次 submit() 真正发出去的字段。重放负控必须重放**这一份** —— 重新取页会拿到
        # 一个新 nonce, 那样"重放"的其实是个从没用过的 nonce, 服务端理所当然放行, 测试就假红了。
        self.last = {}
        self._ctx = ssl.create_default_context()
        # 自签证书 + 固定指纹: 主机名与 CA 链无从校验, 但**指纹**必须逐字对上。
        self._ctx.check_hostname = False
        self._ctx.verify_mode = ssl.CERT_NONE

    def _conn(self):
        c = http.client.HTTPSConnection(self.host, self.port, context=self._ctx,
                                        timeout=self.timeout)
        c.connect()
        der = c.sock.getpeercert(True)
        self.seen_fp = fp_of(der)
        if self.expect_fp and self.seen_fp != self.expect_fp:
            c.close()
            raise FormError("证书指纹与独立渠道取到的不一致(前 8 位: %s vs %s)"
                            % (self.seen_fp[:11], self.expect_fp[:11]))
        return c

    def request(self, method, path, body=None, drop_before_read=False):
        c = self._conn()
        hdr = {}
        if self.jar:
            hdr["Cookie"] = "; ".join("%s=%s" % kv for kv in self.jar.items())
        if body is not None:
            hdr["Content-Type"] = "application/x-www-form-urlencoded"
        c.request(method, path, body=body, headers=hdr)
        if drop_before_read:
            c.sock.close()          # 收尾断线: 服务端正准备回写时把连接扯掉
            return 0, ""
        r = c.getresponse()
        data = r.read().decode("utf-8", "replace")
        for k, v in r.getheaders():
            if k.lower() == "set-cookie":
                piece = v.split(";", 1)[0]
                if "=" in piece:
                    n, val = piece.split("=", 1)
                    self.jar[n.strip()] = val.strip()
        st, loc = r.status, r.getheader("Location")
        c.close()
        if st in (301, 302, 303) and loc and loc.startswith("/"):
            return self.request("GET", loc)      # 只跟站内跳转
        return st, data

    def login(self, token):
        st, body = self.request("GET", "/")
        f = find_form(body, "/login")
        fields = dict(f["fields"])
        if "token" not in fields:
            raise FormError("登录表单里没有 token 字段: %r" % sorted(fields))
        fields["token"] = token
        st, body = self.request(f["method"].upper(), f["action"],
                                urllib.parse.urlencode(fields))
        return st, body

    def submit(self, page_path, action_contains, checks=(), drop_before_read=False,
               tamper=None):
        """打开页面 → 取那张表单 → 按原样提交(复选框按需勾上)。

        checks: 要勾上的复选框名; tamper: {字段: 新值} —— 只给负控用, 正常路径不传。"""
        st, body = self.request("GET", page_path)
        if st != 200:
            raise FormError("打不开 %s(st=%s)" % (page_path, st))
        f = find_form(body, action_contains)
        fields = dict(f["fields"])
        for name in f["checkboxes"]:
            if name in checks:
                fields[name] = fields.get(name) or "on"
            else:
                fields.pop(name, None)          # 没勾的复选框浏览器根本不提交
        for name in checks:
            if name not in f["checkboxes"] and name not in fields:
                raise FormError("页面上没有要勾的 %r" % name)
        if tamper:
            fields.update(tamper)
        self.last = dict(fields)
        return self.request(f["method"].upper(), f["action"],
                            urllib.parse.urlencode(fields), drop_before_read=drop_before_read)


def snapshot_ids(html_text):
    return sorted(set(re.findall(r"/snapshot/(\d{8}-\d{6})", html_text or "")))
