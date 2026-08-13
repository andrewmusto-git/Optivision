#!/usr/bin/env python3
"""
Optivision JDBC to Veza OAA connector.

This script reads users and role assignments from Optivision over JDBC and
pushes a CustomApplication payload to Veza.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from logging.handlers import TimedRotatingFileHandler
from pathlib import Path
from typing import Any

import jaydebeapi
from dotenv import load_dotenv
from oaaclient.client import OAAClient, OAAClientError
from oaaclient.templates import CustomApplication, OAAPermission

log = logging.getLogger(__name__)

STATIC_DRIVER_CLASS = "com.microsoft.sqlserver.jdbc.SQLServerDriver"
DEFAULT_ACCOUNT_SQL = (
    "SELECT ua.vers_id, ua.user_id, ua.domain_name, ua.type_code, ua.user_name, "
    "ua.employee_id, ua.email_address, ua.phone_num, ua.mill_id, ua.department_id, "
    "ua.work_location, ua.supervisor, ua.supers_email_address, ua.ts_expire, "
    "ua.comment_line, ua.active_flag, ua.ts_installed, ua.ts_create, ua.ts_modified, "
    "ur.role_id, ur.seq_num "
    "FROM [opticov].[opticov].[user_account] ua "
    "LEFT JOIN [user_role] ur ON ua.user_id = ur.user_id "
    "WHERE ua.active_flag = 'Y'"
)
DEFAULT_ROLE_SQL = "SELECT DISTINCT role_id FROM role ORDER BY role_id"


@dataclass
class UserRecord:
    user_id: str
    user_name: str
    email_address: str
    active_flag: str
    attributes: dict[str, Any]


def _setup_logging(log_level: str = "INFO") -> None:
    """Configure file-only logging with hourly rotation to the logs/ folder."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    log_dir = os.path.join(script_dir, "logs")
    os.makedirs(log_dir, exist_ok=True)

    timestamp = datetime.now().strftime("%d%m%Y-%H%M")
    script_name = os.path.splitext(os.path.basename(__file__))[0]
    log_file = os.path.join(log_dir, f"{script_name}_{timestamp}.log")

    handler = TimedRotatingFileHandler(
        log_file,
        when="h",
        interval=1,
        backupCount=24,
        encoding="utf-8",
    )
    handler.setFormatter(
        logging.Formatter(
            fmt="%(asctime)s %(levelname)-8s %(message)s",
            datefmt="%Y-%m-%dT%H:%M:%S",
        )
    )

    root = logging.getLogger()
    root.setLevel(getattr(logging, log_level.upper(), logging.INFO))
    root.addHandler(handler)


def _normalize_location(value: str) -> str:
    cleaned = re.sub(r"\s+", "-", value.strip())
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "", cleaned)
    return cleaned or "default"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Optivision JDBC connector for Veza OAA")
    parser.add_argument("--data-dir", default="./samples", help="Not used for JDBC; kept for CLI compatibility")
    parser.add_argument("--env-file", default=".env", help="Path to .env file")
    parser.add_argument("--veza-url", default=None, help="Veza tenant URL")
    parser.add_argument("--veza-api-key", default=None, help="Veza API key")
    parser.add_argument("--provider-name", default="Optivision", help="Provider name in Veza")
    parser.add_argument("--datasource-name", default=None, help="Datasource name in Veza")
    parser.add_argument("--dry-run", action="store_true", help="Build payload without pushing to Veza")
    parser.add_argument("--save-json", action="store_true", help="Save payload JSON locally")
    parser.add_argument("--log-level", default="INFO", choices=["DEBUG", "INFO", "WARNING", "ERROR"])

    parser.add_argument("--location", default=None, help="Optivision location label, used in datasource naming")
    parser.add_argument("--jdbc-url", default=None, help="JDBC URL")
    parser.add_argument("--jdbc-database-name", default=None, help="Database name for this location")
    parser.add_argument("--jdbc-user", default=None, help="JDBC username")
    parser.add_argument("--jdbc-password", default=None, help="JDBC password")
    parser.add_argument("--jdbc-driver-class", default=STATIC_DRIVER_CLASS, help="JDBC driver class")
    parser.add_argument("--jdbc-jar-path", default=None, help="Path to JDBC driver jar")
    parser.add_argument("--account-sql", default=None, help="SQL query for accounts and role joins")
    parser.add_argument("--role-sql", default=None, help="SQL query for role catalog")
    return parser.parse_args()


def _cfg_value(arg_value: str | None, env_name: str, fallback: str | None = None) -> str | None:
    if arg_value:
        return arg_value
    env_value = os.getenv(env_name)
    if env_value:
        return env_value
    return fallback


def load_config(args: argparse.Namespace) -> dict[str, Any]:
    if args.env_file and os.path.exists(args.env_file):
        load_dotenv(args.env_file)

    location = _cfg_value(args.location, "OPTIVISION_LOCATION", "default")
    location = _normalize_location(location or "default")

    datasource_name = (
        args.datasource_name
        or os.getenv("DATASOURCE_NAME")
        or f"Optivision-{location}"
    )

    config = {
        "veza_url": _cfg_value(args.veza_url, "VEZA_URL"),
        "veza_api_key": _cfg_value(args.veza_api_key, "VEZA_API_KEY"),
        "provider_name": _cfg_value(args.provider_name, "PROVIDER_NAME", "Optivision"),
        "datasource_name": datasource_name,
        "location": location,
        "jdbc_url": _cfg_value(args.jdbc_url, "JDBC_URL"),
        "jdbc_database_name": _cfg_value(args.jdbc_database_name, "JDBC_DATABASE_NAME"),
        "jdbc_user": _cfg_value(args.jdbc_user, "JDBC_USER"),
        "jdbc_password": _cfg_value(args.jdbc_password, "JDBC_PASSWORD"),
        "jdbc_driver_class": _cfg_value(
            args.jdbc_driver_class,
            "JDBC_DRIVER_CLASS",
            STATIC_DRIVER_CLASS,
        ),
        "jdbc_jar_path": _cfg_value(args.jdbc_jar_path, "JDBC_JAR_PATH"),
        "account_sql": _cfg_value(args.account_sql, "ACCOUNT_SQL", DEFAULT_ACCOUNT_SQL),
        "role_sql": _cfg_value(args.role_sql, "ROLE_SQL", DEFAULT_ROLE_SQL),
    }

    required = ["veza_url", "veza_api_key", "jdbc_url", "jdbc_user", "jdbc_password", "jdbc_jar_path"]
    missing = [k for k in required if not config.get(k)]
    if missing and not args.dry_run:
        raise ValueError(f"Missing required configuration values: {', '.join(missing)}")

    return config


def _jdbc_fetch_rows(conn: Any, sql_text: str) -> list[dict[str, Any]]:
    cursor = conn.cursor()
    try:
        cursor.execute(sql_text)
        columns = [desc[0] for desc in cursor.description] if cursor.description else []
        rows = cursor.fetchall()
    finally:
        cursor.close()

    out: list[dict[str, Any]] = []
    for row in rows:
        values = list(row)
        out.append({columns[idx]: values[idx] for idx in range(len(columns))})
    return out


def fetch_optivision_data(config: dict[str, Any]) -> dict[str, Any]:
    log.info("Connecting to JDBC source for location %s", config["location"])
    conn = jaydebeapi.connect(
        config["jdbc_driver_class"],
        config["jdbc_url"],
        [config["jdbc_user"], config["jdbc_password"]],
        config["jdbc_jar_path"],
    )

    try:
        account_rows = _jdbc_fetch_rows(conn, config["account_sql"])
        role_rows = _jdbc_fetch_rows(conn, config["role_sql"])
    finally:
        conn.close()

    users: dict[str, UserRecord] = {}
    memberships: dict[str, set[str]] = defaultdict(set)
    roles: set[str] = set()

    for row in account_rows:
        user_id = str(row.get("user_id", "")).strip()
        if not user_id:
            continue

        roles_for_row = str(row.get("role_id", "")).strip()
        if roles_for_row:
            memberships[user_id].add(roles_for_row)
            roles.add(roles_for_row)

        active_flag = str(row.get("active_flag", "Y")).strip().upper() or "Y"
        users[user_id] = UserRecord(
            user_id=user_id,
            user_name=str(row.get("user_name", "")).strip() or user_id,
            email_address=str(row.get("email_address", "")).strip(),
            active_flag=active_flag,
            attributes={
                "employee_id": str(row.get("employee_id", "")).strip(),
                "department_id": str(row.get("department_id", "")).strip(),
                "work_location": str(row.get("work_location", "")).strip(),
                "mill_id": str(row.get("mill_id", "")).strip(),
                "domain_name": str(row.get("domain_name", "")).strip(),
            },
        )

    for row in role_rows:
        role_id = str(row.get("role_id", "")).strip()
        if role_id:
            roles.add(role_id)

    log.info("Fetched %d users and %d roles from JDBC", len(users), len(roles))
    return {
        "users": users,
        "roles": sorted(roles),
        "memberships": memberships,
    }


def _try_calls(candidates: list[tuple[str, Any]]) -> Any:
    last_error: Exception | None = None
    for label, call in candidates:
        try:
            return call()
        except TypeError as exc:
            last_error = exc
            log.debug("Skipping incompatible call signature: %s (%s)", label, exc)
        except Exception as exc:
            last_error = exc
            log.debug("Call attempt failed: %s (%s)", label, exc)
    if last_error:
        raise last_error
    raise RuntimeError("No call candidates provided")


def _add_permission(app: CustomApplication) -> None:
    _try_calls(
        [
            ("add_custom_permission(name, permissions)", lambda: app.add_custom_permission("access", [OAAPermission.DataRead])),
            (
                "add_custom_permission(name=..., permissions=...)",
                lambda: app.add_custom_permission(name="access", permissions=[OAAPermission.DataRead]),
            ),
            ("add_custom_permission(name)", lambda: app.add_custom_permission("access")),
        ]
    )


def _add_local_user(app: CustomApplication, user: UserRecord) -> Any:
    user_obj = _try_calls(
        [
            ("add_local_user(name, email, is_active)", lambda: app.add_local_user(user.user_id, user.email_address, user.active_flag == "Y")),
            ("add_local_user(name)", lambda: app.add_local_user(user.user_id)),
            (
                "add_local_user(name=...)",
                lambda: app.add_local_user(name=user.user_id),
            ),
        ]
    )

    for key, value in user.attributes.items():
        if not value:
            continue
        try:
            _try_calls(
                [
                    ("set_property(key, value)", lambda: user_obj.set_property(key, value)),
                    ("add_property(key, value)", lambda: user_obj.add_property(key, value)),
                    ("set_custom_property(key, value)", lambda: user_obj.set_custom_property(key, value)),
                ]
            )
        except Exception:
            log.debug("User property not set for %s.%s", user.user_id, key)
    return user_obj


def _add_local_group(app: CustomApplication, role_id: str) -> Any:
    return _try_calls(
        [
            ("add_local_group(name)", lambda: app.add_local_group(role_id)),
            ("add_local_group(name=...)", lambda: app.add_local_group(name=role_id)),
            ("add_group(name)", lambda: app.add_group(role_id)),
        ]
    )


def _bind_user_to_group(app: CustomApplication, user_obj: Any, group_obj: Any) -> None:
    candidates = []
    for fn_name in ["add_member", "add_user", "add_local_user"]:
        if hasattr(group_obj, fn_name):
            fn = getattr(group_obj, fn_name)
            candidates.append((f"group.{fn_name}(user_obj)", lambda fn=fn: fn(user_obj)))
            candidates.append((f"group.{fn_name}(user_name)", lambda fn=fn: fn(getattr(user_obj, "name", None) or str(user_obj))))

    for fn_name in ["add_group_member", "add_user_to_group", "add_membership"]:
        if hasattr(app, fn_name):
            fn = getattr(app, fn_name)
            candidates.append((f"app.{fn_name}(group_obj, user_obj)", lambda fn=fn: fn(group_obj, user_obj)))
            candidates.append((f"app.{fn_name}(group_name, user_name)", lambda fn=fn: fn(getattr(group_obj, "name", str(group_obj)), getattr(user_obj, "name", str(user_obj)))))

    if not candidates:
        return

    try:
        _try_calls(candidates)
    except Exception:
        log.debug("Could not bind user to group for SDK version in use")


def build_oaa_payload(data: dict[str, Any], config: dict[str, Any]) -> tuple[CustomApplication, dict[str, int]]:
    app = CustomApplication(name=config["datasource_name"], application_type=config["provider_name"])
    _add_permission(app)

    group_cache: dict[str, Any] = {}
    role_memberships = 0

    users = data["users"]
    roles = data["roles"]
    memberships = data["memberships"]

    for role_id in roles:
        group_cache[role_id] = _add_local_group(app, role_id)

    for user_id, user in users.items():
        user_obj = _add_local_user(app, user)
        for role_id in sorted(memberships.get(user_id, set())):
            group_obj = group_cache.get(role_id)
            if group_obj is None:
                continue
            _bind_user_to_group(app, user_obj, group_obj)
            role_memberships += 1

    counts = {
        "users": len(users),
        "roles": len(roles),
        "resources": 0,
        "permissions": 1,
        "memberships": role_memberships,
    }
    return app, counts


def save_payload_json(app: CustomApplication, config: dict[str, Any]) -> str:
    script_dir = Path(__file__).resolve().parent
    output_dir = script_dir / "output"
    output_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    payload_path = output_dir / f"optivision_{config['location']}_{timestamp}.json"

    payload_obj: Any
    for fn_name in ["to_json", "to_dict", "as_dict", "serialize", "json"]:
        if not hasattr(app, fn_name):
            continue
        fn = getattr(app, fn_name)
        try:
            payload_obj = fn()
            if isinstance(payload_obj, str):
                payload_obj = json.loads(payload_obj)
            break
        except Exception:
            payload_obj = None
    else:
        payload_obj = {
            "datasource": config["datasource_name"],
            "provider": config["provider_name"],
            "note": "SDK object serialization method unavailable; summary fallback written.",
        }

    payload_path.write_text(json.dumps(payload_obj, indent=2), encoding="utf-8")
    log.info("Saved payload JSON to %s", payload_path)
    return str(payload_path)


def push_to_veza(config: dict[str, Any], app: CustomApplication, dry_run: bool) -> dict[str, Any] | None:
    if dry_run:
        log.info("Dry-run requested: payload built and push skipped")
        return None

    veza = OAAClient(url=config["veza_url"], token=config["veza_api_key"])
    try:
        return _try_calls(
            [
                (
                    "push_application(provider_name, data_source_name, application_object, create_provider)",
                    lambda: veza.push_application(
                        provider_name=config["provider_name"],
                        data_source_name=config["datasource_name"],
                        application_object=app,
                        create_provider=True,
                    ),
                ),
                (
                    "push_application(provider_name, datasource_name, application_object, create_provider)",
                    lambda: veza.push_application(
                        provider_name=config["provider_name"],
                        datasource_name=config["datasource_name"],
                        application_object=app,
                        create_provider=True,
                    ),
                ),
                (
                    "push_application(provider_name, data_source_name, application_object)",
                    lambda: veza.push_application(
                        provider_name=config["provider_name"],
                        data_source_name=config["datasource_name"],
                        application_object=app,
                    ),
                ),
            ]
        )
    except OAAClientError as exc:
        log.error("Veza push failed: %s - %s (HTTP %s)", exc.error, exc.message, exc.status_code)
        if hasattr(exc, "details"):
            for detail in exc.details:
                log.error("Veza detail: %s", detail)
        raise


def main() -> int:
    args = parse_args()
    _setup_logging(args.log_level)

    try:
        config = load_config(args)
        data = fetch_optivision_data(config)
        app, counts = build_oaa_payload(data, config)

        payload_path = None
        if args.save_json:
            payload_path = save_payload_json(app, config)

        response = push_to_veza(config, app, args.dry_run)
        if response and response.get("warnings"):
            for warning in response["warnings"]:
                log.warning("Veza warning: %s", warning)

        log.info(
            "Completed datasource=%s users=%d roles=%d resources=%d permissions=%d memberships=%d",
            config["datasource_name"],
            counts["users"],
            counts["roles"],
            counts["resources"],
            counts["permissions"],
            counts["memberships"],
        )
        if payload_path:
            log.info("Payload path: %s", payload_path)
        return 0
    except Exception as exc:
        log.exception("Connector execution failed: %s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
