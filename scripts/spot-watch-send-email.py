#!/usr/bin/env python3
"""Spot 巡检报告邮件 · 126 SMTP（读取 diting-src/.env 的 COPILOT_SMTP_*）

[Ref: 31_Spot计费感知与巡检规约.md]
"""
from __future__ import annotations

import argparse
import json
import os
import smtplib
import ssl
import sys
from datetime import datetime, timezone
from email.message import EmailMessage
from pathlib import Path


def _load_dotenv(path: Path) -> None:
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = val


def _read_prefs(infra_root: Path) -> dict:
    prefs_path = infra_root / "config" / "spot-billing-prefs.yaml"
    if not prefs_path.is_file():
        return {}
    try:
        import yaml  # type: ignore
    except ImportError:
        return {}
    return yaml.safe_load(prefs_path.read_text(encoding="utf-8")) or {}


def _billing_state_summary(infra_root: Path) -> str:
    state_path = infra_root / "config" / ".spot-billing-state.json"
    if not state_path.is_file():
        return "（无 billing state）"
    data = json.loads(state_path.read_text(encoding="utf-8"))
    lines = []
    for stack_id in ("proxy", "base"):
        entry = data.get(stack_id) or {}
        lines.append(
            f"  · {stack_id}: intent={entry.get('operational_intent', '?')} "
            f"billing={entry.get('billing', '?')} "
            f"instance={entry.get('instance_id', '-')} "
            f"eip={entry.get('eip_address', '-')} "
            f"last_down={entry.get('last_down_at', '-')}"
        )
    return "\n".join(lines)


def _conclusion_emoji(code: str) -> str:
    return {
        "HEALTHY": "✅",
        "PREEMPTED_LIKELY": "⚠️",
        "UNEXPECTED_RELEASE": "❌",
        "SPOT_OPPORTUNITY": "💡",
        "BALANCE_BLOCK": "💰",
        "EIP_LINGERING": "🔗",
    }.get(code, "ℹ️")


def send_report(
    infra_root: Path,
    conclusion: str,
    detail: str,
    action: str,
) -> bool:
    prefs = _read_prefs(infra_root)
    email_cfg = prefs.get("watch_email") or {}
    if email_cfg.get("enabled") is False:
        print("ℹ️  [spot-watch-email] watch_email.enabled=false · 跳过发信")
        return True

    smtp_rel = email_cfg.get("smtp_env_file") or "../diting-src/.env"
    smtp_env = (infra_root / smtp_rel).resolve()
    _load_dotenv(smtp_env)

    host = os.environ.get("COPILOT_SMTP_HOST", "smtp.126.com")
    port = int(os.environ.get("COPILOT_SMTP_PORT", "465"))
    use_ssl = os.environ.get("COPILOT_SMTP_USE_SSL", "true").lower() in ("1", "true", "yes")
    username = os.environ.get("COPILOT_SMTP_USERNAME", "")
    password = os.environ.get("COPILOT_SMTP_PASSWORD", "")
    sender = os.environ.get("COPILOT_SMTP_FROM") or username
    to_addr = (
        os.environ.get("SPOT_WATCH_EMAIL_TO")
        or email_cfg.get("to")
        or username
    )

    if not username or not password or not to_addr:
        print(
            "⚠️  [spot-watch-email] 缺 SMTP 凭证或收件地址 "
            f"(env={smtp_env} · user={'ok' if username else '缺'} · to={to_addr or '缺'})",
            file=sys.stderr,
        )
        return False

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    emoji = _conclusion_emoji(conclusion)
    subject = f"[Diting Spot Guard] {emoji} {conclusion} · {now}"
    billing = _billing_state_summary(infra_root)
    text_body = (
        f"Diting 集群 Spot 巡检报告\n\n"
        f"结论: {conclusion}\n"
        f"详情: {detail}\n"
        f"建议: {action or '无'}\n"
        f"时间: {now}\n\n"
        f"计费状态:\n{billing}\n\n"
        f"交互切换: cd diting-infra && make cluster-spot-watch INTERACTIVE=1\n"
    )
    html_body = f"""<html><body style="font-family:sans-serif">
<h2>{emoji} Spot 巡检 · {conclusion}</h2>
<p><strong>详情</strong>：{detail}</p>
<p><strong>建议</strong>：{action or '无'}</p>
<p><strong>时间</strong>：{now}</p>
<pre>{billing}</pre>
<p style="color:#666">cron 仅报告不自动切换 · 需 <code>make cluster-spot-watch INTERACTIVE=1</code></p>
</body></html>"""

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = sender
    msg["To"] = to_addr
    msg.set_content(text_body)
    msg.add_alternative(html_body, subtype="html")

    try:
        if use_ssl:
            context = ssl.create_default_context()
            with smtplib.SMTP_SSL(host, port, context=context, timeout=30) as smtp:
                smtp.login(username, password)
                smtp.send_message(msg)
        else:
            with smtplib.SMTP(host, port, timeout=30) as smtp:
                smtp.starttls(context=ssl.create_default_context())
                smtp.login(username, password)
                smtp.send_message(msg)
        print(f"✅ [spot-watch-email] 已发送至 {to_addr} · 结论={conclusion}")
        return True
    except Exception as exc:  # noqa: BLE001
        print(f"❌ [spot-watch-email] 发送失败: {exc!r}", file=sys.stderr)
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description="Spot 巡检报告发邮件")
    parser.add_argument("--infra-root", required=True)
    parser.add_argument("--conclusion", required=True)
    parser.add_argument("--detail", default="")
    parser.add_argument("--action", default="")
    args = parser.parse_args()
    ok = send_report(
        Path(args.infra_root),
        args.conclusion,
        args.detail,
        args.action,
    )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
