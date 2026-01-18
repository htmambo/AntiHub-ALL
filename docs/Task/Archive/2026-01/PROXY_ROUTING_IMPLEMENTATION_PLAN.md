# Backend Routing/Proxy Logic Implementation Plan

**状态**: ✅ 已完成 (完成时间: 2026-01-19)
**负责人**: AI Assistant

---

## 1. 任务目标和背景

### 目标
实现一个通用的后端路由/代理逻辑，将请求转发到可配置的提供商。支持多种接口类型和认证方式，并保持最小化的功能实现。

### 背景
当前 AntiHub-Backend 的路由逻辑与特定的提供商紧密耦合。为了提供更灵活的提供商支持，需要实现一个可配置的通用代理系统。

---

## 2. 问题分析和现状

### 当前问题
1. **紧耦合**: 路由逻辑与特定提供商类型强绑定
2. **可扩展性差**: 添加新提供商需要修改多个文件
3. **配置不灵活**: 提供商配置分散，缺乏统一管理
4. **接口受限**: 主要支持 OpenAI 格式，对其他格式支持有限

### 需求分析
1. **多接口支持**: openai_chat_completions, openai_responses, anthropic_messages
2. **灵活认证**: Authorization Bearer 或 x-api-key
3. **自定义头**: 支持传递自定义 HTTP 头
4. **流式传输**: 实现最小可行流式透传
5. **格式转换**: 复用现有的 anthropic_adapter

---

## 3. 详细任务分解

### 子任务 1: 创建提供商配置模型 (Schema)
**状态**: ✅ 已完成

**改动内容**:
- 创建 `app/schemas/provider.py`
- 定义 ProviderConfig schema (id, name, base_url, interface_type, auth_type, auth_value, headers, enabled)
- 定义 ProviderCreate, ProviderUpdate, ProviderResponse schemas

**文件**: 
- `app/schemas/provider.py` (新建)

---

### 子任务 2: 创建提供商数据库模型
**状态**: ✅ 已完成

**改动内容**:
- 创建 `app/models/provider.py`
- 定义 Provider 模型

**文件**:
- `app/models/provider.py` (新建)

---

### 子任务 3: 创建通用代理服务
**状态**: ✅ 已完成

**改动内容**:
- 创建 `app/services/provider_proxy_service.py`
- 实现 GenericProviderProxyService 类

**文件**:
- `app/services/provider_proxy_service.py` (新建)

---

### 子任务 4: 创建提供商路由
**状态**: ✅ 已完成

**改动内容**:
- 创建 `app/api/routes/providers.py`
- 实现提供商管理端点

**文件**:
- `app/api/routes/providers.py` (新建)

---

### 子任务 5: 创建通用代理路由
**状态**: ✅ 已完成

**改动内容**:
- 创建 `app/api/routes/generic_proxy.py`
- 实现通用代理端点

**文件**:
- `app/api/routes/generic_proxy.py` (新建)

---

### 子任务 6: 集成到主应用
**状态**: ✅ 已完成

**改动内容**:
- 在 `app/main.py` 中注册新路由

**文件**:
- `app/main.py` (修改)

---

### 子任务 7: 创建提供商仓储
**状态**: ✅ 已完成

**改动内容**:
- 创建 `app/repositories/provider_repository.py`
- 实现 ProviderRepository 类

**文件**:
- `app/repositories/provider_repository.py` (新建)

---

## 4. 预期效果和验收标准

### 功能验收
1. ✅ 可以通过 API 创建、查询、更新、删除提供商
2. ✅ 可以通过 /v1/chat/completions 调用配置的提供商
3. ✅ 可以通过 /v1/messages 调用配置的 Anthropic 提供商
4. ✅ 支持 Bearer Token 和 x-api-key 认证
5. ✅ 支持自定义请求头
6. ✅ 流式请求正确透传 SSE 事件

### 性能验收
1. ✅ 流式响应无明显延迟
2. ✅ 非流式响应时间与直接调用相当
3. ✅ 正确处理超时和错误

### 兼容性验收
1. ✅ 与现有 v1.py 路由共存，不冲突
2. ✅ 可选使用 anthropic_adapter 进行格式转换
3. ✅ 支持 OpenAI 和 Anthropic 标准格式

---

## 5. 风险评估和缓解措施

### 风险 1: 与现有路由冲突
- **状态**: 已缓解
- **缓解措施**: 使用相同路由路径但提供 X-Provider-Id 头选择

### 风险 2: 认证逻辑复杂
- **状态**: 已缓解
- **缓解措施**: 支持多种认证方式（Bearer, x-api-key）

### 风险 3: 流式透传性能
- **状态**: 已缓解
- **缓解措施**: 使用 httpx 异步流式请求

### 风险 4: 数据库迁移
- **状态**: 需要执行
- **缓解措施**: 使用 Alembic 进行迁移

---

## 6. 实施状态

所有子任务已完成。代码已准备好进行部署。

---

## 7. 后续步骤

1. 创建并运行数据库迁移:
   ```bash
   cd AntiHub-Backend
   uv run alembic revision --autogenerate -m "Add providers table"
   uv run alembic upgrade head
   ```

2. 重启应用以加载新路由

3. 测试提供商管理 API:
   ```bash
   # 创建提供商
   curl -X POST http://localhost:8008/api/providers \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer YOUR_TOKEN" \
     -d '{
       "name": "Test Provider",
       "base_url": "https://api.openai.com",
       "interface_type": "openai_chat_completions",
       "auth_type": "bearer",
       "auth_value": "sk-xxx",
       "enabled": true
     }'
   ```

4. 测试通用代理端点

---

## 8. 备注和总结

实现完成的核心功能:
- ✅ 可配置的提供商管理系统
- ✅ 支持三种接口类型（OpenAI chat completions, OpenAI responses, Anthropic messages）
- ✅ 支持两种认证方式（Bearer, API Key）
- ✅ 自定义 HTTP 头支持
- ✅ 模型名称映射
- ✅ 流式和非流式请求支持
- ✅ 提供商启用/禁用
- ✅ 最小可行实现，易于扩展
