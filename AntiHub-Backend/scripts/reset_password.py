#!/usr/bin/env python3
"""
独立密码重置脚本
用于本地开发场景，直接重置指定用户名的密码
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
import asyncio

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine


def normalize_database_url(raw_url: str) -> str:
    if raw_url.startswith("postgresql+asyncpg://"):
        return raw_url
    if raw_url.startswith("postgresql+psycopg2://"):
        return "postgresql+asyncpg://" + raw_url.split("://", 1)[1]
    if raw_url.startswith("postgresql://"):
        return "postgresql+asyncpg://" + raw_url.split("://", 1)[1]
    if raw_url.startswith("postgres://"):
        return "postgresql+asyncpg://" + raw_url.split("://", 1)[1]
    return raw_url


def build_database_url_from_env() -> str:
    host = os.getenv("POSTGRES_HOST", "localhost")
    port = os.getenv("POSTGRES_PORT", "5432")
    user = os.getenv("POSTGRES_USER", "postgres")
    password = os.getenv("POSTGRES_PASSWORD", "")
    db = os.getenv("POSTGRES_DB", "postgres")
    if password:
        return f"postgresql+asyncpg://{user}:{password}@{host}:{port}/{db}"
    return f"postgresql+asyncpg://{user}@{host}:{port}/{db}"


def load_env_file(path: Path, override: bool) -> None:
    if not path.exists():
        return

    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("export "):
            stripped = stripped[7:].strip()
        if "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        if not key:
            continue
        if override or key not in os.environ:
            os.environ[key] = value


def load_env_files(repo_root: Path, backend_root: Path) -> None:
    # 先加载根目录 .env，再允许后端目录覆盖
    load_env_file(repo_root / ".env", override=False)
    load_env_file(backend_root / ".env", override=True)


async def reset_password(username: str, password: str, database_url: str) -> int:
    from app.core.security import hash_password
    from app.models.user import User

    engine = create_async_engine(database_url, echo=False)
    session_maker: async_sessionmaker[AsyncSession] = async_sessionmaker(
        engine,
        class_=AsyncSession,
        expire_on_commit=False,
        autoflush=False,
        autocommit=False,
    )

    async with session_maker() as session:
        result = await session.execute(select(User).where(User.username == username))
        user = result.scalar_one_or_none()
        if not user:
            print(f"用户不存在: {username}")
            await engine.dispose()
            return 1

        user.password_hash = hash_password(password)
        user.is_active = True
        user.is_silenced = False
        await session.commit()

    await engine.dispose()
    print(f"已重置用户密码并确保可用: {username}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="重置指定用户的密码")
    parser.add_argument("--username", help="用户名")
    parser.add_argument("--password", help="新密码")
    parser.add_argument("--from-env", action="store_true", help="使用 ADMIN_USERNAME/ADMIN_PASSWORD")
    parser.add_argument("--database-url", help="显式指定 DATABASE_URL（可选）")
    args = parser.parse_args()

    backend_root = Path(__file__).resolve().parents[1]
    repo_root = backend_root.parent
    sys.path.insert(0, str(backend_root))

    load_env_files(repo_root, backend_root)

    username = args.username
    password = args.password

    if args.from_env or not username or not password:
        username = username or os.getenv("ADMIN_USERNAME")
        password = password or os.getenv("ADMIN_PASSWORD")

    if not username or not password:
        print("缺少用户名或密码。请传 --username/--password 或使用 --from-env。")
        return 2

    database_url = args.database_url or os.getenv("DATABASE_URL")
    if not database_url:
        database_url = build_database_url_from_env()

    database_url = normalize_database_url(database_url)

    return asyncio.run(reset_password(username, password, database_url))


if __name__ == "__main__":
    raise SystemExit(main())
