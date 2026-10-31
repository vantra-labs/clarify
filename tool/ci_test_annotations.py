"""Превращает упавшие тесты из `flutter test --reporter json` в аннотации GitHub.

Аннотации видны в PR и через API без скачивания полного лога прогона.
"""
import json
import sys

tests, errors = {}, {}
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    e = json.loads(line)
    t = e.get("type")
    if t == "testStart":
        tests[e["test"]["id"]] = e["test"]
    elif t == "error":
        errors.setdefault(e["testID"], []).append(e.get("error", "") + "\n" + e.get("stackTrace", ""))
    elif t == "testDone" and e.get("result") != "success" and not e.get("hidden"):
        test = tests.get(e["testID"], {})
        url = test.get("root_url") or test.get("url") or ""
        path = url.split("/frontend/")[-1].replace("file://", "")
        if "/test/" in path:
            path = "test/" + path.split("/test/")[-1]
        line_no = test.get("root_line") or test.get("line") or 1
        msg = "\n".join(errors.get(e["testID"], ["(без текста ошибки)"]))[:3000]
        msg = msg.replace("%", "%25").replace("\r", "").replace("\n", "%0A")
        name = test.get("name", "?").replace(",", " ").replace("::", ":")
        print(f"::error file={path},line={line_no},title={name}::{msg}")
