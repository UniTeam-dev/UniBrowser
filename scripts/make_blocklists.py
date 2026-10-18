#!/usr/bin/env python3
"""EasyList + EasyPrivacy -> WebKit content-blocker JSON in Shared/Site/Blocklists/.

The generated files are data and are committed; the apps never download lists.
Run from the repo root:
    python3 -I scripts/make_blocklists.py           # downloads both lists, writes blocklist-N.json
    python3 -I scripts/make_blocklists.py --check   # self-check of the converter, no network

Covers the common Adblock Plus syntax WebKit can express: URL patterns with || | ^ *,
$third-party, resource types, $domain=, $match-case, @@ exceptions and element hiding
(##, #@#). Regex rules, scriptlets, extended CSS and options WebKit has no action for
($redirect, $csp, $removeparam, $popup, $document, ...) are skipped.
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

LISTS = [
    "https://easylist.to/easylist/easylist.txt",
    "https://easylist.to/easylist/easyprivacy.txt",
]
OUT = Path(__file__).resolve().parent.parent / "Shared" / "Site" / "Blocklists"
MAX_RULES = 150_000
CHUNK = 50_000  # rules per WKContentRuleList, exceptions included

# ABP type option -> WebKit resource-type
TYPES = {
    "script": ["script"], "image": ["image"], "stylesheet": ["style-sheet"], "font": ["font"],
    "media": ["media"], "object": ["media"], "xmlhttprequest": ["raw"], "websocket": ["raw"],
    "ping": ["ping"], "other": ["other"], "subdocument": ["document"],
}
ALL_TYPES = sorted({t for v in TYPES.values() for t in v})
IGNORED_OPTIONS = {"important", "~important"}
UNSUPPORTED_CSS = (":-abp-", ":has-text(", ":contains(", ":xpath(", ":upward(", ":remove(", ":style(",
                   ":matches-css", ":watch-attr", ":min-text-length", ":matches-attr", ":nth-ancestor",
                   ":matches-path", ":has(", ":is(", ":not(:")
SEPARATOR = "[/:?=&]"


def pattern_to_regex(pattern):
    """ABP URL pattern -> WebKit url-filter, or None if WebKit can't express it."""
    if len(pattern) > 1 and pattern.startswith("/") and pattern.endswith("/"):
        return None  # regex rule; WebKit's subset rarely matches ABP's
    if not pattern.isascii():
        return None
    prefix = ""
    if pattern.startswith("||"):
        prefix, pattern = "^[^:]+://+([^/]+\\.)?", pattern[2:]
    elif pattern.startswith("|"):
        prefix, pattern = "^", pattern[1:]
    suffix = ""
    if pattern.endswith("|"):
        suffix, pattern = "$", pattern[:-1]
    elif pattern.endswith("^"):
        pattern = pattern[:-1]
        if prefix.startswith("^[^:]") and not any(c in pattern for c in "/*^?"):
            suffix = "[/:]"  # a bare host: WebKit's normalized URL always has / or :port after it
        else:
            # A separator or the end of the URL; WebKit has no alternation.
            suffix = "(" + SEPARATOR + ".*)?$"
    pattern = pattern.strip("*") if not prefix else pattern.rstrip("*")
    body = ""
    for c in pattern:
        if c == "*":
            body += ".*"
        elif c == "^":
            body += SEPARATOR
        elif c in ".?+()[]{}|\\$":
            body += "\\" + c
        else:
            body += c
    regex = prefix + body + suffix
    return regex or ".*"


def domains(value):
    """'a.com|~b.com' -> (['*a.com'], ['*b.com']) or None if a domain isn't usable."""
    include, exclude = [], []
    for d in value.split("|"):
        negated = d.startswith("~")
        d = d.lstrip("~").strip().lower()
        if not d or "*" in d or "/" in d:
            return None
        try:
            d = d.encode("idna").decode("ascii")
        except UnicodeError:
            return None
        (exclude if negated else include).append("*" + d)
    return include, exclude


def apply_domains(trigger, include, exclude):
    # WebKit can't combine if-domain and unless-domain; the positive list is the stricter one.
    if include:
        trigger["if-domain"] = include
    elif exclude:
        trigger["unless-domain"] = exclude


def network_rule(line):
    """One ABP network filter -> (rule, is_exception) or None."""
    exception = line.startswith("@@")
    if exception:
        line = line[2:]
    options = []
    if "$" in line and not line.endswith("/"):
        line, _, opts = line.rpartition("$")
        options = [o.strip() for o in opts.split(",") if o.strip()]
    regex = pattern_to_regex(line)
    if regex is None:
        return None
    trigger = {"url-filter": regex}
    types, not_types = [], []
    child_frame = False
    for option in options:
        name, _, value = option.partition("=")
        name = name.lower()
        if name in ("third-party", "3p"):
            trigger["load-type"] = ["third-party"]
        elif name in ("~third-party", "1p", "first-party"):
            trigger["load-type"] = ["first-party"]
        elif name == "match-case":
            trigger["url-filter-is-case-sensitive"] = True
        elif name == "domain":
            parsed = domains(value)
            if parsed is None:
                return None
            apply_domains(trigger, *parsed)
        elif name in TYPES:
            types += TYPES[name]
            child_frame |= name == "subdocument"
        elif name.startswith("~") and name[1:] in TYPES:
            not_types += TYPES[name[1:]]
        elif name in IGNORED_OPTIONS:
            continue
        else:
            return None  # $popup, $document, $redirect, $csp, $removeparam, ...
    if types and not_types:
        return None
    if not_types:
        types = [t for t in ALL_TYPES if t not in not_types]
    if types:
        trigger["resource-type"] = sorted(set(types))
        if child_frame and types == ["document"]:
            trigger["load-context"] = ["child-frame"]
    elif not exception:
        # Without a type ABP never blocks the page itself; neither should WebKit.
        trigger["resource-type"] = [t for t in ALL_TYPES if t != "document"]
    action = {"type": "ignore-previous-rules" if exception else "block"}
    return {"trigger": trigger, "action": action}, exception


def css_supported(selector):
    return selector.isascii() and not any(token in selector for token in UNSUPPORTED_CSS)


def convert(lines):
    """ABP filter lines -> (block rules, element-hiding rules, exception rules)."""
    blocks, exceptions = [], []
    hiding = {}  # selector -> list of (include, exclude) domain sets; generic = ([], [])
    hiding_exceptions = {}  # selector -> list of domains where it must not hide
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith(("!", "[")):
            continue
        if "#@#" in line:
            left, _, selector = line.partition("#@#")
            parsed = domains(left.replace(",", "|")) if left else ([], [])
            if parsed and parsed[0]:
                hiding_exceptions.setdefault(selector, []).extend(parsed[0])
            continue
        if "##" in line:
            left, _, selector = line.partition("##")
            if selector.startswith(("+js", "^")) or not css_supported(selector):
                continue
            parsed = domains(left.replace(",", "|")) if left else ([], [])
            if parsed is None:
                continue
            hiding.setdefault(selector, []).append(parsed)
            continue
        if "#?#" in line or "#$#" in line or "#%#" in line:
            continue
        converted = network_rule(line)
        if converted:
            rule, is_exception = converted
            (exceptions if is_exception else blocks).append(rule)
    css = []
    for selector, scopes in hiding.items():
        for include, exclude in scopes:
            if not include:
                # Generic, or generic minus some sites: #@# turns into unless-domain.
                exclude = exclude + hiding_exceptions.get(selector, [])
            trigger = {"url-filter": ".*"}
            apply_domains(trigger, include, sorted(set(exclude)))
            css.append({"trigger": trigger, "action": {"type": "css-display-none", "selector": selector}})
    return blocks, css, exceptions


def chunks(blocks, css, exceptions):
    """Rule lists WebKit accepts. Exceptions only reach rules in their own list, so every list gets all of them."""
    rules = (blocks + css)[: MAX_RULES - len(exceptions)]
    room = CHUNK - len(exceptions)
    assert room > 0, "too many exception rules for one list"
    return [rules[i:i + room] + exceptions for i in range(0, len(rules), room)]


def main():
    lines = []
    for url in LISTS:
        request = urllib.request.Request(url, headers={"User-Agent": "UniBrowser make_blocklists"})
        with urllib.request.urlopen(request, timeout=60) as response:
            lines += response.read().decode("utf-8").splitlines()
    blocks, css, exceptions = convert(lines)
    lists = chunks(blocks, css, exceptions)
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("blocklist-*.json"):
        old.unlink()
    for index, rules in enumerate(lists, 1):
        (OUT / f"blocklist-{index}.json").write_text(json.dumps(rules, separators=(",", ":")))
    print(f"{len(blocks)} block, {len(css)} hiding, {len(exceptions)} exception rules -> {len(lists)} lists in {OUT}")


def check():
    r = pattern_to_regex
    assert r("||ads.example.com^") == "^[^:]+://+([^/]+\\.)?ads\\.example\\.com[/:]"
    assert r("||x.com/ad^") == "^[^:]+://+([^/]+\\.)?x\\.com/ad([/:?=&].*)?$"
    assert r("|https://x.com/a*b|") == "^https://x\\.com/a.*b$"
    assert r("/banner/*/img^") == "/banner/.*/img([/:?=&].*)?$"
    assert r("&ad_type=") == "&ad_type="
    assert r("/^ad[0-9]/") is None
    assert r("*") == ".*"
    rule, exc = network_rule("||tracker.com^$third-party,script,domain=a.com|~b.a.com")
    assert not exc and rule["trigger"]["load-type"] == ["third-party"]
    assert rule["trigger"]["resource-type"] == ["script"] and rule["trigger"]["if-domain"] == ["*a.com"]
    assert "unless-domain" not in rule["trigger"]
    rule, exc = network_rule("@@||cdn.com/ads.js$script")
    assert exc and rule["action"]["type"] == "ignore-previous-rules"
    assert network_rule("||x.com^$popup") is None
    assert network_rule("||x.com^$redirect=noop.js") is None
    assert "document" not in network_rule("||x.com^")[0]["trigger"]["resource-type"]
    sub = network_rule("||x.com^$subdocument")[0]["trigger"]
    assert sub["resource-type"] == ["document"] and sub["load-context"] == ["child-frame"]
    assert "script" not in network_rule("||x.com^$~script")[0]["trigger"]["resource-type"]
    blocks, css, exceptions = convert([
        "! comment", "[Adblock Plus 2.0]", "##.ad-banner", "example.com,~sub.example.com##.promo",
        "news.com#@#.ad-banner", "##div:-abp-has(.x)", "site.com#?#.y", "||ads.com^", "@@||ads.com/ok^",
    ])
    assert len(blocks) == 1 and len(exceptions) == 1
    generic = next(c for c in css if c["action"]["selector"] == ".ad-banner")
    assert generic["trigger"]["unless-domain"] == ["*news.com"]
    promo = next(c for c in css if c["action"]["selector"] == ".promo")
    assert promo["trigger"]["if-domain"] == ["*example.com"]
    assert all(":-abp-" not in c["action"]["selector"] for c in css)
    lists = chunks([{"b": i} for i in range(7)], [], [{"e": 0}])
    global CHUNK
    assert len(lists) == 1 and lists[0][-1] == {"e": 0}
    CHUNK, saved = 4, CHUNK
    lists = chunks([{"b": i} for i in range(7)], [], [{"e": 0}])
    CHUNK = saved
    assert [len(l) for l in lists] == [4, 4, 2] and all(l[-1] == {"e": 0} for l in lists)
    print("make_blocklists: ok")


if __name__ == "__main__":
    check() if "--check" in sys.argv else main()
