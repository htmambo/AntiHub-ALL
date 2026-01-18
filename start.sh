#!/bin/bash

################################################################################
# AntiHub-ALL 项目启动脚本
#
# 功能：
#   - 开发模式：本地运行各服务（不使用 Docker）
#   - 生产模式：使用 Docker Compose
#   - 环境检查、依赖安装、数据库初始化等
#
# 使用方法：
#   ./start.sh [命令] [选项]
#
# 命令：
#   dev         启动开发模式
#   prod        启动生产模式（Docker）
#   stop        停止所有服务
#   restart     重启所有服务
#   status      查看服务状��
#   logs        查看服务日志
#   install     安装依赖
#   init-db     初始化数据库
#   gen-key     生成加密密钥
#   health      健康检查
#   clean       清理数据和容器
#   help        显示帮助信息
################################################################################

set -e  # 遇到错误立即退出

# 颜色定义（非 TTY 或禁用颜色时置空）
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MAGENTA=''
    CYAN=''
    NC=''
fi

# 项目根目录
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

# 配置
FRONTEND_DIR="$PROJECT_ROOT/AntiHub"
BACKEND_DIR="$PROJECT_ROOT/AntiHub-Backend"
PLUGIN_DIR="$PROJECT_ROOT/AntiHub-plugin"

# PID 文件
PIDS_DIR="$PROJECT_ROOT/.pids"
mkdir -p "$PIDS_DIR"

FRONTEND_PID="$PIDS_DIR/frontend.pid"
BACKEND_PID="$PIDS_DIR/backend.pid"
PLUGIN_PID="$PIDS_DIR/plugin.pid"

################################################################################
# 辅助函数
################################################################################

# 打印带颜色的消息
print_info() {
    printf '%b\n' "${BLUE}[INFO]${NC} $1"
}

print_success() {
    printf '%b\n' "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    printf '%b\n' "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    printf '%b\n' "${RED}[ERROR]${NC} $1"
}

print_header() {
    printf '%b\n' "${MAGENTA}========================================${NC}"
    printf '%b\n' "${MAGENTA}$1${NC}"
    printf '%b\n' "${MAGENTA}========================================${NC}"
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查端口是否被占用
check_port() {
    local port=$1
    if command_exists lsof; then
        lsof -i ":$port" >/dev/null 2>&1
    elif command_exists netstat; then
        netstat -an | grep ":$port " | grep LISTEN >/dev/null 2>&1
    else
        return 1
    fi
}

# 等待端口就绪
wait_for_port() {
    local host=$1
    local port=$2
    local timeout=${3:-30}
    local count=0

    print_info "等待 $host:$port 就绪..."

    while ! nc -z "$host" "$port" >/dev/null 2>&1; do
        count=$((count + 1))
        if [ $count -ge $timeout ]; then
            print_error "等待 $host:$port 超时"
            return 1
        fi
        sleep 1
    done

    print_success "$host:$port 已就绪"
}

################################################################################
# 环境检查函数
################################################################################

check_env_file() {
    if [ ! -f "$PROJECT_ROOT/.env" ]; then
        print_warning ".env 文件不存在，正在从 .env.example 创建..."
        cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
        print_warning "请编辑 .env 文件配置必要的环境变量"
        return 1
    fi
    return 0
}

load_env_file() {
    if [ -f "$PROJECT_ROOT/.env" ]; then
        set -a
        . "$PROJECT_ROOT/.env"
        set +a
        return 0
    fi
    return 1
}

ensure_backend_database_url() {
    if [ -n "${DATABASE_URL:-}" ]; then
        case "$DATABASE_URL" in
            postgresql+asyncpg://*)
                return 0
                ;;
            postgresql+psycopg2://*)
                DATABASE_URL="postgresql+asyncpg://${DATABASE_URL#postgresql+psycopg2://}"
                ;;
            postgresql://*)
                DATABASE_URL="postgresql+asyncpg://${DATABASE_URL#postgresql://}"
                ;;
            postgres://*)
                DATABASE_URL="postgresql+asyncpg://${DATABASE_URL#postgres://}"
                ;;
            *)
                return 0
                ;;
        esac
        export DATABASE_URL
        print_warning "DATABASE_URL 未使用 asyncpg 驱动，已自动切换为 postgresql+asyncpg"
        return 0
    fi

    local host="${POSTGRES_HOST:-localhost}"
    local port="${POSTGRES_PORT:-5432}"
    local user="${POSTGRES_USER:-postgres}"
    local password="${POSTGRES_PASSWORD:-}"
    local db="${POSTGRES_DB:-postgres}"

    if [ -n "$password" ]; then
        DATABASE_URL="postgresql+asyncpg://${user}:${password}@${host}:${port}/${db}"
    else
        DATABASE_URL="postgresql+asyncpg://${user}@${host}:${port}/${db}"
    fi

    export DATABASE_URL
    print_warning "DATABASE_URL 未设置，已根据 POSTGRES_* 生成"
}

check_node() {
    if ! command_exists node; then
        print_error "Node.js 未安装，请先安装 Node.js (>=18.0.0)"
        return 1
    fi

    local node_version=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
    if [ "$node_version" -lt 18 ]; then
        print_error "Node.js 版本过低 (当前: $(node -v)，需要: >=18.0.0)"
        return 1
    fi

    print_success "Node.js 版本检查通过: $(node -v)"
    return 0
}

check_python() {
    if ! command_exists python3; then
        print_error "Python3 未安装，请先安装 Python3 (>=3.10)"
        return 1
    fi

    local python_version=$(python3 --version | cut -d' ' -f2 | cut -d'.' -f1,2)
    print_success "Python 版本检查通过: $(python3 --version)"
    return 0
}

check_docker() {
    if ! command_exists docker; then
        print_error "Docker 未安装，请先安装 Docker"
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        print_error "Docker 守护进程未运行，请启动 Docker"
        return 1
    fi

    print_success "Docker 检查通过: $(docker --version)"
    return 0
}

check_postgres() {
    if check_port 5432 || check_port 5434; then
        print_success "检测到 PostgreSQL 服务正在运行"
        return 0
    else
        print_warning "未检测到 PostgreSQL 服务，请确保数据库已启动"
        return 1
    fi
}

check_redis() {
    if check_port 6379; then
        print_success "检测到 Redis 服务正在运行"
        return 0
    else
        print_warning "未检测到 Redis 服务"
        return 1
    fi
}

################################################################################
# 依赖安装函数
################################################################################

install_frontend_deps() {
    print_header "安装前端依赖"

    cd "$FRONTEND_DIR"
    if [ ! -d "node_modules" ]; then
        print_info "安装前端 node_modules..."
        npm install --ignore-scripts --no-audit --no-fund
        print_success "前端依赖安装完成"
    else
        print_info "前端依赖已存在，跳过安装"
    fi
}

install_backend_deps() {
    print_header "安装后端依赖"

    cd "$BACKEND_DIR"
    if [ ! -d "venv" ]; then
        print_info "创建 Python 虚拟环境..."
        python3 -m venv venv
        print_success "虚拟环境创建完成"
    fi

    print_info "激活虚拟环境并安装依赖..."
    source venv/bin/activate
    pip install --upgrade pip
    if [ -f "requirements.txt" ]; then
        pip install -r requirements.txt
    else
        pip install \
            fastapi==0.104.1 \
            uvicorn[standard]==0.24.0 \
            sqlalchemy==2.0.23 \
            asyncpg==0.29.0 \
            alembic==1.12.1 \
            redis==5.0.1 \
            pyjwt==2.8.0 \
            passlib[bcrypt]==1.7.4 \
            cryptography==41.0.7 \
            httpx==0.25.2 \
            pydantic==2.5.2 \
            pydantic-settings==2.1.0 \
            python-dotenv==1.0.0 \
            python-multipart==0.0.6
    fi
    print_success "后端依赖安装完成"
}

install_plugin_deps() {
    print_header "安装插件服务依赖"

    cd "$PLUGIN_DIR"
    if [ ! -d "node_modules" ]; then
        print_info "安装插件服务 node_modules..."
        npm install --ignore-scripts --no-audit --no-fund
        print_success "插件服务依赖安装完成"
    else
        print_info "插件服务依赖已存在，跳过安装"
    fi
}

install_deps() {
    print_header "安装所有依赖"

    check_node || exit 1
    check_python || exit 1

    install_frontend_deps
    install_backend_deps
    install_plugin_deps

    print_success "所有依赖安装完成"
}

################################################################################
# 开发模式函数
################################################################################

generate_plugin_config_from_env() {
    local config_path="$PLUGIN_DIR/config.json"
    if [ -f "$config_path" ]; then
        return 0
    fi

    if ! load_env_file; then
        print_error ".env 文件不存在，无法生成插件配置"
        return 1
    fi

    local server_port="${PLUGIN_PORT:-${PORT:-8045}}"
    local server_host="${PLUGIN_HOST:-127.0.0.1}"
    local db_host="${PLUGIN_DB_HOST:-${DB_HOST:-${POSTGRES_HOST:-localhost}}}"
    local db_port="${PLUGIN_DB_PORT:-${DB_PORT:-${POSTGRES_PORT:-5432}}}"
    local db_name="${PLUGIN_DB_NAME:-${DB_NAME:-${POSTGRES_DB:-antigravity}}}"
    local db_user="${PLUGIN_DB_USER:-${DB_USER:-${POSTGRES_USER:-postgres}}}"
    local db_password="${PLUGIN_DB_PASSWORD:-${DB_PASSWORD:-${POSTGRES_PASSWORD:-postgres}}}"
    local redis_host="${PLUGIN_REDIS_HOST:-${REDIS_HOST:-localhost}}"
    local redis_port="${PLUGIN_REDIS_PORT:-${REDIS_PORT:-6379}}"
    local redis_password="${PLUGIN_REDIS_PASSWORD:-${REDIS_PASSWORD:-}}"
    local oauth_callback="${PLUGIN_OAUTH_CALLBACK_URL:-${OAUTH_CALLBACK_URL:-http://localhost:${server_port}/api/oauth/callback}}"
    local admin_api_key="${PLUGIN_ADMIN_API_KEY:-${ADMIN_API_KEY:-sk-admin-default-key}}"

    if [ -z "$server_port" ]; then
        server_port=8045
    fi
    if [ -z "$db_port" ]; then
        db_port=5432
    fi
    if [ -z "$redis_port" ]; then
        redis_port=6379
    fi

    cat > "$config_path" <<EOF
{
  "server": {
    "port": ${server_port},
    "host": "${server_host}"
  },
  "database": {
    "host": "${db_host}",
    "port": ${db_port},
    "database": "${db_name}",
    "user": "${db_user}",
    "password": "${db_password}",
    "max": 20,
    "idleTimeoutMillis": 30000,
    "connectionTimeoutMillis": 2000
  },
  "redis": {
    "host": "${redis_host}",
    "port": ${redis_port},
    "password": "${redis_password}",
    "db": 0
  },
  "oauth": {
    "callbackUrl": "${oauth_callback}"
  },
  "security": {
    "maxRequestSize": "50mb",
    "adminApiKey": "${admin_api_key}"
  }
}
EOF

    print_success "已生成插件配置文件: $config_path"
}

start_frontend_dev() {
    print_header "启动前端服务 (开发模式)"

    cd "$FRONTEND_DIR"

    if check_port 3000; then
        print_warning "端口 3000 已被占用，尝试停止旧进程..."
        stop_frontend_dev
    fi

    print_info "启动 Next.js 开发服务器..."
    nohup npm run dev > "$PIDS_DIR/frontend.log" 2>&1 &
    echo $! > "$FRONTEND_PID"

    sleep 3

    if [ -f "$FRONTEND_PID" ] && kill -0 $(cat "$FRONTEND_PID") 2>/dev/null; then
        print_success "前端服务已启动 (PID: $(cat $FRONTEND_PID))"
        print_info "访问地址: http://localhost:3000"
        print_info "日志文件: $PIDS_DIR/frontend.log"
    else
        print_error "前端服务启动失败"
        cat "$PIDS_DIR/frontend.log"
        return 1
    fi
}

start_backend_dev() {
    print_header "启动后端服务 (开发模式)"

    cd "$BACKEND_DIR"

    if check_port 8000; then
        print_warning "端口 8000 已被占用，尝试停止旧进程..."
        stop_backend_dev
    fi

    if [ ! -d "venv" ]; then
        print_error "虚拟环境不存在，请先运行: ./start.sh install"
        return 1
    fi

    print_info "激活虚拟环境并启动 FastAPI 服务器..."
    source venv/bin/activate

    # 加载环境变量
    load_env_file || true
    ensure_backend_database_url

    nohup uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload > "$PIDS_DIR/backend.log" 2>&1 &
    echo $! > "$BACKEND_PID"

    sleep 3

    if [ -f "$BACKEND_PID" ] && kill -0 $(cat "$BACKEND_PID") 2>/dev/null; then
        print_success "后端服务已启动 (PID: $(cat $BACKEND_PID))"
        print_info "访问地址: http://localhost:8000"
        print_info "API 文档: http://localhost:8000/docs"
        print_info "日志文件: $PIDS_DIR/backend.log"
    else
        print_error "后端服务启动失败"
        cat "$PIDS_DIR/backend.log"
        return 1
    fi
}

start_plugin_dev() {
    print_header "启动插件服务 (开发模式)"

    cd "$PLUGIN_DIR"

    generate_plugin_config_from_env || return 1

    if check_port 8045; then
        print_warning "端口 8045 已被占用，尝试停止旧进程..."
        stop_plugin_dev
    fi

    print_info "启动插件服务..."
    nohup npm run dev > "$PIDS_DIR/plugin.log" 2>&1 &
    echo $! > "$PLUGIN_PID"

    sleep 3

    if [ -f "$PLUGIN_PID" ] && kill -0 $(cat "$PLUGIN_PID") 2>/dev/null; then
        print_success "插件服务已启动 (PID: $(cat $PLUGIN_PID))"
        print_info "访问地址: http://localhost:8045"
        print_info "日志文件: $PIDS_DIR/plugin.log"
    else
        print_error "插件服务启动失败"
        cat "$PIDS_DIR/plugin.log"
        return 1
    fi
}

start_dev() {
    print_header "AntiHub-ALL 开发模式启动"

    check_env_file || {
        print_error "请先配置 .env 文件"
        exit 1
    }

    check_node || exit 1
    check_python || exit 1

    # 检查依赖
    if [ ! -d "$FRONTEND_DIR/node_modules" ] || [ ! -d "$BACKEND_DIR/venv" ] || [ ! -d "$PLUGIN_DIR/node_modules" ]; then
        print_warning "检测到缺少依赖，开始安装..."
        install_deps
    fi

    # 启动服务
    start_plugin_dev
    wait_for_port 127.0.0.1 8045 30 || exit 1

    start_backend_dev
    wait_for_port 127.0.0.1 8000 30 || exit 1

    start_frontend_dev
    wait_for_port 127.0.0.1 3000 30 || exit 1

    echo ""
    print_success "==================================="
    print_success "所有服务已成功启动！"
    print_success "==================================="
    echo ""
    print_info "前端地址: ${CYAN}http://localhost:3000${NC}"
    print_info "后端地址: ${CYAN}http://localhost:8000${NC}"
    print_info "后端文档: ${CYAN}http://localhost:8000/docs${NC}"
    print_info "插件地址: ${CYAN}http://localhost:8045${NC}"
    echo ""
    print_info "查看日志: ${CYAN}./start.sh logs [frontend|backend|plugin]${NC}"
    print_info "停止服务: ${CYAN}./start.sh stop${NC}"
    echo ""
}

################################################################################
# 停止服务函数
################################################################################

stop_frontend_dev() {
    if [ -f "$FRONTEND_PID" ]; then
        local pid=$(cat "$FRONTEND_PID")
        if kill -0 "$pid" 2>/dev/null; then
            print_info "停止前端服务 (PID: $pid)..."
            kill "$pid"
            rm -f "$FRONTEND_PID"
            print_success "前端服务已停止"
        else
            rm -f "$FRONTEND_PID"
        fi
    fi

    # 强制清理端口
    if command_exists lsof; then
        lsof -ti:3000 | xargs kill -9 2>/dev/null || true
    fi
}

stop_backend_dev() {
    if [ -f "$BACKEND_PID" ]; then
        local pid=$(cat "$BACKEND_PID")
        if kill -0 "$pid" 2>/dev/null; then
            print_info "停止后端服务 (PID: $pid)..."
            kill "$pid"
            rm -f "$BACKEND_PID"
            print_success "后端服务已停止"
        else
            rm -f "$BACKEND_PID"
        fi
    fi

    # 强制清理端口
    if command_exists lsof; then
        lsof -ti:8000 | xargs kill -9 2>/dev/null || true
    fi
}

stop_plugin_dev() {
    if [ -f "$PLUGIN_PID" ]; then
        local pid=$(cat "$PLUGIN_PID")
        if kill -0 "$pid" 2>/dev/null; then
            print_info "停止插件服务 (PID: $pid)..."
            kill "$pid"
            rm -f "$PLUGIN_PID"
            print_success "插件服务已停止"
        else
            rm -f "$PLUGIN_PID"
        fi
    fi

    # 强制清理端口
    if command_exists lsof; then
        lsof -ti:8045 | xargs kill -9 2>/dev/null || true
    fi
}

stop_dev() {
    print_header "停止所有开发服务"
    stop_frontend_dev
    stop_backend_dev
    stop_plugin_dev
    print_success "所有开发服务已停止"
}

restart_dev() {
    local target=${1:-all}

    case "$target" in
        frontend)
            print_header "重启前端服务 (开发模式)"
            stop_frontend_dev
            start_frontend_dev
            wait_for_port 127.0.0.1 3000 30 || return 1
            ;;
        backend)
            check_env_file || {
                print_error "请先配置 .env 文件"
                return 1
            }
            print_header "重启后端服务 (开发模式)"
            stop_backend_dev
            start_backend_dev
            wait_for_port 127.0.0.1 8000 30 || return 1
            ;;
        plugin)
            check_env_file || {
                print_error "请先配置 .env 文件"
                return 1
            }
            print_header "重启插件服务 (开发模式)"
            stop_plugin_dev
            start_plugin_dev
            wait_for_port 127.0.0.1 8045 30 || return 1
            ;;
        all)
            check_env_file || {
                print_error "请先配置 .env 文件"
                return 1
            }
            print_header "重启所有开发服务"
            stop_dev
            start_dev
            ;;
        *)
            print_error "未知服务: $target"
            echo "可用选项: frontend, backend, plugin, all"
            return 1
            ;;
    esac
}

################################################################################
# 生产模式函数 (Docker)
################################################################################

start_prod() {
    print_header "AntiHub-ALL 生产模式启动 (Docker)"

    check_docker || exit 1
    check_env_file || {
        print_error "请先配置 .env 文件"
        exit 1
    }

    print_info "启动 Docker Compose 服务..."
    docker compose up -d

    print_success "Docker 服务已启动"

    # 等待服务就绪
    print_info "等待服务就绪..."
    sleep 5

    # 检查服务状态
    docker compose ps

    echo ""
    print_success "==================================="
    print_success "Docker 服务启动成功！"
    print_success "==================================="
    echo ""
    print_info "前端地址: ${CYAN}http://localhost:3000${NC}"
    print_info "后端地址: ${CYAN}http://localhost:8000${NC}"
    print_info "后端文档: ${CYAN}http://localhost:8000/docs${NC}"
    echo ""
    print_info "查看日志: ${CYAN}docker compose logs -f${NC}"
    print_info "停止服务: ${CYAN}docker compose down${NC}"
    echo ""
}

stop_prod() {
    print_header "停止 Docker 服务"
    docker compose down
    print_success "Docker 服务已停止"
}

restart_prod() {
    print_header "重启 Docker 服务"
    docker compose restart
    print_success "Docker 服务已重启"
}

################################################################################
# 状态和日志函数
################################################################################

show_status() {
    print_header "服务状态"

    # 检查开发模式进程
    printf '%b\n' "${CYAN}开发模式服务:${NC}"
    if [ -f "$FRONTEND_PID" ] && kill -0 $(cat "$FRONTEND_PID") 2>/dev/null; then
        printf '%b\n' "  前端: ${GREEN}运行中${NC} (PID: $(cat $FRONTEND_PID))"
    else
        printf '%b\n' "  前端: ${RED}未运行${NC}"
    fi

    if [ -f "$BACKEND_PID" ] && kill -0 $(cat "$BACKEND_PID") 2>/dev/null; then
        printf '%b\n' "  后端: ${GREEN}运行中${NC} (PID: $(cat $BACKEND_PID))"
    else
        printf '%b\n' "  后端: ${RED}未运行${NC}"
    fi

    if [ -f "$PLUGIN_PID" ] && kill -0 $(cat "$PLUGIN_PID") 2>/dev/null; then
        printf '%b\n' "  插件: ${GREEN}运行中${NC} (PID: $(cat $PLUGIN_PID))"
    else
        printf '%b\n' "  插件: ${RED}未运行${NC}"
    fi

    echo ""

    # 检查 Docker 容器
    if command_exists docker; then
        printf '%b\n' "${CYAN}Docker 容器:${NC}"
        docker compose ps 2>/dev/null || printf '%b\n' "  ${YELLOW}Docker Compose 未运行${NC}"
    fi
}

show_logs() {
    local service=$1

    case "$service" in
        frontend)
            if [ -f "$PIDS_DIR/frontend.log" ]; then
                tail -f "$PIDS_DIR/frontend.log"
            else
                print_error "前端日志文件不存在"
            fi
            ;;
        backend)
            if [ -f "$PIDS_DIR/backend.log" ]; then
                tail -f "$PIDS_DIR/backend.log"
            else
                print_error "后端日志文件不存在"
            fi
            ;;
        plugin)
            if [ -f "$PIDS_DIR/plugin.log" ]; then
                tail -f "$PIDS_DIR/plugin.log"
            else
                print_error "插件日志文件不存在"
            fi
            ;;
        docker)
            docker compose logs -f
            ;;
        all)
            print_info "显示所有服务日志..."
            docker compose logs -f
            ;;
        *)
            print_error "未知服务: $service"
            echo "可用选项: frontend, backend, plugin, docker, all"
            exit 1
            ;;
    esac
}

################################################################################
# 辅助工具函数
################################################################################

generate_encryption_key() {
    print_header "生成 PLUGIN_API_ENCRYPTION_KEY"

    if [ -d "$BACKEND_DIR/venv" ]; then
        cd "$BACKEND_DIR"
        source venv/bin/activate
        python generate_encryption_key.py
    else
        print_info "使用 Python 生成密钥..."
        python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
    fi

    print_success "请将生成的密钥复制到 .env 文件的 PLUGIN_API_ENCRYPTION_KEY"
}

init_database() {
    print_header "初始化数据库"

    check_env_file || {
        print_error "请先配置 .env 文件"
        exit 1
    }

    # 使用 Docker Compose 初始化
    if command_exists docker; then
        print_info "使用 Docker 初始化数据库..."
        docker compose run --rm backend python -c "
import asyncio
from app.core.database import get_db
from app.repositories.user_repository import UserRepository
from app.core.config import get_settings

async def init():
    settings = get_settings()
    if settings.admin_username and settings.admin_password:
        db = get_db()
        repo = UserRepository(db)
        existing = await repo.get_by_username(settings.admin_username)
        if not existing:
            await repo.create({
                'username': settings.admin_username,
                'password': settings.admin_password,
                'is_admin': True
            })
            print('管理员账号创建成功')
        else:
            print('管理员账号已存在')
        await db.close()
    else:
        print('未配置 ADMIN_USERNAME 和 ADMIN_PASSWORD，跳过管理员创建')

asyncio.run(init())
"
        print_success "数据库初始化完成"
    else
        print_warning "Docker 未安装，跳过数据库初始化"
    fi
}

health_check() {
    print_header "健康检查"

    printf '%b\n' "${CYAN}检查服务端口:${NC}"

    # 前端
    if check_port 3000; then
        printf '%b\n' "  前端 (3000): ${GREEN}✓${NC}"
    else
        printf '%b\n' "  前端 (3000): ${RED}✗${NC}"
    fi

    # 后端
    if check_port 8000; then
        printf '%b\n' "  后端 (8000): ${GREEN}✓${NC}"
        # 检查 API
        if command_exists curl; then
            if curl -s http://localhost:8000/health >/dev/null 2>&1 || curl -s http://localhost:8000/api/health >/dev/null 2>&1; then
                printf '%b\n' "    后端 API: ${GREEN}✓${NC}"
            else
                printf '%b\n' "    后端 API: ${YELLOW}?${NC} (端口开放但无法访问)"
            fi
        fi
    else
        printf '%b\n' "  后端 (8000): ${RED}✗${NC}"
    fi

    # 插件
    if check_port 8045; then
        printf '%b\n' "  插件 (8045): ${GREEN}✓${NC}"
    else
        printf '%b\n' "  插件 (8045): ${RED}✗${NC}"
    fi

    # PostgreSQL
    if check_port 5432 || check_port 5434; then
        printf '%b\n' "  PostgreSQL: ${GREEN}✓${NC}"
    else
        printf '%b\n' "  PostgreSQL: ${RED}✗${NC}"
    fi

    # Redis
    if check_port 6379; then
        printf '%b\n' "  Redis: ${GREEN}✓${NC}"
    else
        printf '%b\n' "  Redis: ${RED}✗${NC}"
    fi
}

clean_all() {
    print_header "清理数据和容器"

    print_warning "此操作将删除所有 Docker 容器、卷和数据！"
    read -p "确定要继续吗? (y/N): " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "停止所有服务..."
        stop_dev 2>/dev/null || true

        if command_exists docker; then
            print_info "删除 Docker 容器和卷..."
            docker compose down -v
            docker system prune -f
        fi

        print_info "清理 PID 文件..."
        rm -rf "$PIDS_DIR"

        print_info "清理 node_modules 和 venv..."
        rm -rf "$FRONTEND_DIR/node_modules"
        rm -rf "$BACKEND_DIR/venv"
        rm -rf "$PLUGIN_DIR/node_modules"

        print_success "清理完成"
    else
        print_info "已取消"
    fi
}

################################################################################
# 帮助函数
################################################################################

show_help() {
    cat << EOF
${MAGENTA}AntiHub-ALL 项目启动脚本${NC}

${CYAN}用法:${NC}
    ./start.sh [命令] [选项]

${CYAN}命令:${NC}
    ${GREEN}dev${NC}         启动开发模式 (本地运行各服务)
    ${GREEN}prod${NC}        启动生产模式 (Docker Compose)
    ${GREEN}stop${NC}        停止所有服务 (开发模式)
    ${GREEN}restart${NC}     重启服务（默认开发模式；docker/prod=生产模式）
                        选项: frontend, backend, plugin, all, docker, prod

    ${GREEN}status${NC}      查看所有服务状态
    ${GREEN}logs${NC}        查看服务日志
                        选项: frontend, backend, plugin, docker, all

    ${GREEN}install${NC}     安装所有依赖
    ${GREEN}init-db${NC}     初始化数据库
    ${GREEN}gen-key${NC}     生成 PLUGIN_API_ENCRYPTION_KEY

    ${GREEN}health${NC}      健康检查
    ${GREEN}clean${NC}       清理所有数据、容器和依赖

    ${GREEN}help${NC}        显示此帮助信息

${CYAN}示例:${NC}
    ./start.sh dev           # 启动开发模式
    ./start.sh prod          # 启动生产模式
    ./start.sh logs backend  # 查看后端日志
    ./start.sh restart backend  # 开发模式重启后端
    ./start.sh restart docker   # 生产模式重启
    ./start.sh health        # 健康检查

${CYAN}项目结构:${NC}
    AntiHub/                 前端 (Next.js)
    AntiHub-Backend/         后端 (FastAPI)
    AntiHub-plugin/          插件服务 (Node.js)

EOF
}

################################################################################
# 主函数
################################################################################

main() {
    local command=${1:-help}
    local option=${2:-}

    case "$command" in
        dev)
            start_dev
            ;;
        prod)
            start_prod
            ;;
        stop)
            stop_dev
            ;;
        restart)
            if [ -z "$option" ]; then
                restart_dev all
            else
                case "$option" in
                    docker|prod)
                        restart_prod
                        ;;
                    *)
                        restart_dev "$option"
                        ;;
                esac
            fi
            ;;
        status)
            show_status
            ;;
        logs)
            if [ -z "$option" ]; then
                print_error "请指定要查看的服务日志"
                echo "可用选项: frontend, backend, plugin, docker, all"
                exit 1
            fi
            show_logs "$option"
            ;;
        install)
            install_deps
            ;;
        init-db)
            init_database
            ;;
        gen-key)
            generate_encryption_key
            ;;
        health)
            health_check
            ;;
        clean)
            clean_all
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "未知命令: $command"
            echo "使用 './start.sh help' 查看帮助信息"
            exit 1
            ;;
    esac
}

# 运行主函数
main "$@"
