# Provider-Based Request Forwarding Implementation Plan

**状态**: ⏳ 待执行
**创建时间**: 2026-01-19
**负责人**: System

## 任务目标和背景

实现基于 API Key 的 `provider_id` 将请求转发到可配置的上游提供商的功能。

## 需求分析

### 现有基础设施
- `/v1/chat/completions` 路由：OpenAI 兼容端点 (AntiHub-Backend/app/api/routes/v1.py)
- `/v1/messages` 路由：Anthropic 兼容端点 (AntiHub-Backend/app/api/routes/anthropic.py)
- 现有转换工具：AntiHub-Backend/app/services/anthropic_adapter.py

### 新增数据模型需求

#### Provider 模型
```python
class Provider(Base):
    __tablename__ = "providers"
    
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(100), nullable=False)
    base_url = Column(String(500), nullable=False)
    api_key = Column(Text, nullable=False)  # 加密存储（后续实现）
    auth_type = Column(String(50), default="bearer")  # bearer, x-api-key, either
    custom_headers = Column(JSON, nullable=True)  # 自定义请求头
    enabled_interfaces = Column(JSON, nullable=False)  # 启用的接口列表
    is_active = Column(Boolean, default=True, nullable=False)
    created_at = Column(DateTime, server_default=func.now())
    updated_at = Column(DateTime, onupdate=func.now())
```

#### APIKey 模型变更
- 添加 `provider_id` 字段（可选）

### 接口类型定义
- `openai_chat_completions` - OpenAI /v1/chat/completions
- `openai_responses` - OpenAI /v1/responses
- `anthropic_messages` - Anthropic /v1/messages

## 功能需求

### 1. /v1/chat/completions 路由逻辑
- 如果 API Key 有 `provider_id`：
  - 获取 Provider 配置
  - 如果 Provider 启用 `openai_chat_completions`：
    - 直接转发到 `{base_url}/v1/chat/completions`
  - 否则如果 Provider 启用 `anthropic_messages`：
    - 将 OpenAI 请求转换为 Anthropic 格式
    - 转发到 `{base_url}/v1/messages`
    - 将响应转换回 OpenAI 格式
    - 支持流式响应
  - 否则返回 400 错误
- 如果没有 `provider_id`：使用原有逻辑

### 2. /v1/messages 路由逻辑
- 如果 API Key 有 `provider_id`：
  - 获取 Provider 配置
  - 如果 Provider 启用 `anthropic_messages`：
    - 直接转发到 `{base_url}/v1/messages`
  - 否则返回 400 错误
- 如果没有 `provider_id`：使用原有逻辑

### 3. /v1/responses 路由（新增）
- 如果 API Key 有 `provider_id`：
  - 获取 Provider 配置
  - 如果 Provider 启用 `openai_responses`：
    - 直接转发到 `{base_url}/v1/responses`
  - 否则返回 400 错误
- 如果没有 `provider_id`：返回 400 错误

### 4. 认证和请求头处理
- 支持 Provider 的认证类型：
  - `bearer` - 使用 `Authorization: Bearer {api_key}`
  - `x-api-key` - 使用 `x-api-key: {api_key}`
  - `either` - 尝试两种方式（优先 `bearer`）
- 合并 Provider 的自定义请求头到上游请求
- 不转发客户端的 `Authorization` 或 `x-api-key` 到上游（除非来自 Provider 配置）

### 5. 流式响应支持
- 必须支持上游 SSE/stream 响应的透传
- 在格式转换时保持流式特性

### 6. 新增服务类
- 创建 `UpstreamProxyService` 在 `AntiHub-Backend/app/services/upstream_proxy_service.py`
- 使用 `httpx.AsyncClient` 进行代理请求和流式传输

### 7. 依赖注入更新
- 在 `AntiHub-Backend/app/api/deps.py` 中添加 Provider 相关依赖：
  - `get_provider_by_id()`
  - `get_upstream_proxy_service()`

## 任务分解

### 子任务 1: 创建 Provider 模型和迁移
- [ ] 创建 `app/models/provider.py`
- [ ] 在 `app/models/__init__.py` 中导出
- [ ] 创建 Alembic 迁移文件
- [ ] 更新 APIKey 模型添加 `provider_id` 字段
- [ ] 创建迁移文件

### 子任务 2: 创建 UpstreamProxyService
- [ ] 创建 `app/services/upstream_proxy_service.py`
- [ ] 实现 `proxy_request()` 方法（非流式）
- [ ] 实现 `proxy_stream_request()` 方法（流式）
- [ ] 实现认证类型处理逻辑
- [ ] 实现自定义请求头合并逻辑

### 子任务 3: 创建 Provider Repository
- [ ] 创建 `app/repositories/provider_repository.py`
- [ ] 实现 `get_by_id()` 方法
- [ ] 实现 `get_all_by_user()` 方法（可选）

### 子任务 4: 更新依赖注入
- [ ] 在 `app/api/deps.py` 中添加 `get_provider_service()`
- [ ] 在 `app/api/deps.py` 中添加 `get_upstream_proxy_service()`

### 子任务 5: 更新 /v1/chat/completions 路由
- [ ] 修改 `app/api/routes/v1.py`
- [ ] 添加 Provider 检查逻辑
- [ ] 实现格式转换（如果需要）
- [ ] 实现流式响应转换

### 子任务 6: 更新 /v1/messages 路由
- [ ] 修改 `app/api/routes/anthropic.py`
- [ ] 添加 Provider 检查逻辑
- [ ] 实现直接转发

### 子任务 7: 创建 /v1/responses 路由
- [ ] 在 `app/api/routes/v1.py` 中添加 `/v1/responses` 端点
- [ ] 实现转发逻辑

### 子任务 8: 更新 Schema
- [ ] 创建 `app/schemas/provider.py`
- [ ] 创建 Provider 相关请求/响应模型

### 子任务 9: 测试和验证
- [ ] 测试 Provider 配置创建
- [ ] 测试 /v1/chat/completions 转发（OpenAI 接口）
- [ ] 测试 /v1/chat/completions 转发（格式转换）
- [ ] 测试 /v1/messages 转发
- [ ] 测试 /v1/responses 转发
- [ ] 测试流式响应

## 预期效果

- API Key 可以绑定到特定的 Provider
- 请求根据 Provider 的配置自动路由到正确的上游
- 支持格式转换（OpenAI ↔ Anthropic）
- 完全支持流式响应
- 灵活的认证类型和自定义请求头支持

## 风险评估和缓解措施

### 风险 1: API Key 加密存储
- **风险**: Provider API Key 明文存储存在安全隐患
- **缓解**: 使用 Fernet 加密存储（后续实现），本次先明文存储

### 风险 2: 格式转换完整性
- **风险**: OpenAI ↔ Anthropic 格式转换可能丢失某些字段
- **缓解**: 充分测试常见用例，记录已知限制

### 风险 3: 流式响应处理
- **风险**: 流式响应转换可能出现不同步或错误
- **缓解**: 使用现有的 `anthropic_adapter.py` 作为参考

## 实施顺序

1. 子任务 1: 数据模型
2. 子任务 2: UpstreamProxyService
3. 子任务 3: Provider Repository
4. 子任务 4: 依赖注入
5. 子任务 5-7: 路由更新
6. 子任务 8: Schema
7. 子任务 9: 测试

## 验收标准

- [ ] 创建的 Provider 可以成功存储和检索
- [ ] API Key 可以绑定到 Provider
- [ ] /v1/chat/completions 可以根据 Provider 转发请求
- [ ] /v1/messages 可以根据 Provider 转发请求
- [ ] /v1/responses 可以根据 Provider 转发请求
- [ ] 流式响应正常工作
- [ ] 格式转换正确无误
- [ ] 认证和自定义请求头正确应用

## 备注

- 本次实现假设 Provider 模型已存在或将被创建
- API Key 加密将在后续任务中实现
- 错误处理遵循现有代码风格
