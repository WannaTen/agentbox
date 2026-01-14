# AgentBox 启动配置说明

本文档详细说明 AgentBox 在启动时的文件挂载、复制行为以及配置文件的处理方式。

## 目录

- [启动流程概览](#启动流程概览)
- [文件挂载详情](#文件挂载详情)
- [文件复制详情](#文件复制详情)
- [配置文件处理](#配置文件处理)
- [容器内初始化](#容器内初始化)
- [多实例支持](#多实例支持)

---

## 启动流程概览

```
用户执行: agentbox [选项] [命令]
    ↓
main() 解析参数 (agentbox:816)
    ↓
check_docker() 验证 Docker 守护进程
    ↓
needs_rebuild() 检查是否需要重建镜像 (agentbox:200-221)
    ├─ 计算 Dockerfile + entrypoint.sh 的 SHA256 哈希
    ├─ 比较存储在镜像标签中的哈希
    └─ 如果哈希不匹配或镜像不存在，则需要重建
    ↓
build_image() 构建 Docker 镜像 (如需要) (agentbox:224-254)
    ├─ 传递当前用户/组 ID 作为构建参数
    ├─ 添加 agentbox.hash 标签用于重建检测
    └─ 清理旧镜像
    ↓
run_container() 运行容器 (agentbox:367-562)
    ├─ 构建挂载选项数组
    ├─ 构建端口映射数组
    ├─ 构建环境变量数组
    └─ 执行 docker run
        ↓
    entrypoint.sh 容器内初始化 (entrypoint.sh:1-125)
        ├─ 创建符号链接
        ├─ 初始化开发环境
        ├─ 设置权限
        └─ 配置终端
            ↓
        执行用户命令或启动 Claude CLI
```

---

## 文件挂载详情

### 1. 项目目录挂载

**代码位置**: `agentbox:395-397`

| 挂载源 | 容器目标 | 类型 | 权限 | 说明 |
|--------|---------|------|------|------|
| `$PROJECT_DIR` | `/$PROJECT_NAME` | bind | rw | 当前项目目录，使用项目名称作为容器内路径 |

**示例**:
- 主机: `/home/user/myproject`
- 容器: `/myproject`

### 2. 额外目录挂载

**代码位置**: `agentbox:348-364, 399`

通过 `--add-dir` 参数指定的额外目录会被挂载到容器根目录下，使用目录的 basename 作为容器内路径。

**示例**:
```bash
agentbox --add-dir ~/proj1 --add-dir ~/proj2
```
- 主机: `~/proj1` → 容器: `/proj1`
- 主机: `~/proj2` → 容器: `/proj2`

### 3. SSH 目录挂载

**代码位置**: `agentbox:407-413`

| 挂载源 | 容器目标 | 类型 | 权限 | 说明 |
|--------|---------|------|------|------|
| `~/.agentbox/ssh/` | `/home/claude/.ssh` | bind | rw | SSH 密钥和配置 |

**注意**:
- 首次运行时，`ssh_setup()` 函数会创建此目录并生成 SSH 密钥
- 会从主 SSH 目录复制 `known_hosts` 文件

### 4. 缓存目录挂载

**代码位置**: `agentbox:415-423`

| 挂载源 | 容器目标 | 类型 | 权限 | 说明 |
|--------|---------|------|------|------|
| `~/.cache/agentbox/<hash>/npm` | `/home/claude/.npm` | bind | rw | NPM 缓存 |
| `~/.cache/agentbox/<hash>/pip` | `/home/claude/.cache/pip` | bind | rw | Pip 缓存 |

**哈希计算**: 使用项目目录路径的 SHA256 前 12 位字符
```bash
project_hash=$(echo -n "$PROJECT_DIR" | sha256sum | cut -c1-12)
```

**目的**: 不同项目使用独立的缓存目录，避免依赖冲突

### 5. Shell 历史挂载

**代码位置**: `agentbox:425-434`

| 挂载源 | 容器目标 | 类型 | 权限 | 说明 |
|--------|---------|------|------|------|
| `~/.agentbox/projects/<hash>/history` | `/home/claude/.shell_history` | bind | rw | Shell 命令历史 |

**目的**: 每个项目保持独立的命令历史记录

### 6. Claude 运行时数据卷

**代码位置**: `agentbox:436-445`

| 挂载源 | 容器目标 | 类型 | 权限 | 说明 |
|--------|---------|------|------|------|
| `agentbox-claude-<hash>` | `/home/claude/.claude` | volume | rw | Claude 运行时数据（Docker 命名卷） |

**卷命名规则**:
```bash
agentbox-claude-<project_hash>-<instance_name>
```

**目的**:
- 持久化 Claude 的运行时数据
- 支持多实例运行（每个实例有独立的卷）

### 7. Claude 全局配置绑定挂载

**代码位置**: `agentbox:447-463`

以下配置文件/目录会从主机 `~/.claude/` 直接绑定挂载到容器：

| 配置项 | 主机路径 | 容器路径 | 说明 |
|--------|---------|---------|------|
| `settings.json` | `~/.claude/settings.json` | `/home/claude/.claude/settings.json` | Claude 全局设置 |
| `settings.local.json` | `~/.claude/settings.local.json` | `/home/claude/.claude/settings.local.json` | Claude 本地设置 |
| `.claude.json` | `~/.claude/.claude.json` | `/home/claude/.claude/.claude.json` | Claude 认证数据 |
| `.claude.json.backup` | `~/.claude/.claude.json.backup` | `/home/claude/.claude/.claude.json.backup` | 认证数据备份 |
| `commands` | `~/.claude/commands` | `/home/claude/.claude/commands` | 自定义命令 |
| `ide` | `~/.claude/ide` | `/home/claude/.claude/ide` | IDE 集成配置 |
| `plugins` | `~/.claude/plugins` | `/home/claude/.claude/plugins` | 插件 |
| `skills` | `~/.claude/skills` | `/home/claude/.claude/skills` | 技能 |

**特点**:
- **实时同步**: 绑定挂载实现主机和容器之间的实时双向同步
- **条件挂载**: 只有在主机上存在的配置项才会被挂载
- **读写权限**: 所有配置都以读写模式挂载

### 8. Git 配置挂载（临时）

**代码位置**: `agentbox:471-480`

| 挂载源 | 容器目标 | 类型 | 权限 | 说明 |
|--------|---------|------|------|------|
| `~/.gitconfig` | `/tmp/host_gitconfig` | bind | ro | Git 配置（只读，用于复制） |

**注意**: 此挂载仅用于在容器启动时复制配置，不是实时同步

### 9. Direnv 批准挂载（临时）

**代码位置**: `agentbox:489-518`

| 挂载源 | 容器目标 | 类型 | 权限 | 说明 |
|--------|---------|------|------|------|
| `~/.local/share/direnv/allow` | `/tmp/host_direnv_allow` | bind | ro | Direnv 批准记录（如项目有 .envrc） |

**条件**: 仅当项目目录包含 `.envrc` 文件时才挂载

**目的**: 转换主机的 direnv 批准记录到容器内，避免重复批准

### 10. 环境变量文件

**代码位置**: `agentbox:520-525`

如果项目目录包含 `.env` 文件，会通过 `--env-file` 参数加载：

```bash
docker run --env-file "$PROJECT_DIR/.env" ...
```

### 挂载选项总结

所有挂载都通过 `mount_opts` 数组传递给 `docker run` 命令：

```bash
docker run -it --rm \
    "${mount_opts[@]}" \
    ...
```

---

## 文件复制详情

### 1. Git 配置复制

**代码位置**: `entrypoint.sh:84-95`

**源文件**: `/tmp/host_gitconfig` (从主机 `~/.gitconfig` 挂载)
**目标文件**: `/home/claude/.gitconfig`

**处理逻辑**:
```bash
if [ -f "/tmp/host_gitconfig" ]; then
    cp /tmp/host_gitconfig /home/claude/.gitconfig
else
    # 使用默认配置
    cat > /home/claude/.gitconfig << 'EOF'
[user]
    email = claude@agentbox
    name = Claude (AgentBox)
[init]
    defaultBranch = main
EOF
fi
```

**特点**:
- 单向复制，不会同步回主机
- 如果主机没有 `.gitconfig`，使用默认配置
- 每次容器启动时重新复制

### 2. SSH 密钥复制和生成

**代码位置**: `agentbox:780-813` (`ssh_setup()` 函数)

**首次运行时执行**:

1. **创建 SSH 目录**:
   ```bash
   mkdir -p "${HOME}/.agentbox/ssh"
   chmod 700 "${HOME}/.agentbox/ssh"
   ```

2. **复制 known_hosts**:
   ```bash
   if [[ -f "${HOME}/.ssh/known_hosts" ]]; then
       cp "${HOME}/.ssh/known_hosts" "${agentbox_ssh}/known_hosts"
       chmod 600 "${agentbox_ssh}/known_hosts"
   fi
   ```

3. **生成新的 SSH 密钥对**:
   ```bash
   ssh-keygen -t ed25519 \
       -f "${agentbox_ssh}/id_ed25519" \
       -C "agentbox@$(hostname)" \
       -N ""
   ```

**特点**:
- 只在首次运行时执行
- 为 AgentBox 生成独立的 SSH 密钥
- 复制主机的 known_hosts 以避免首次连接警告

### 3. Volume 数据导出

**代码位置**: `agentbox:668-701` (`pull_from_volume()` 函数)

**命令**: `agentbox pull`

**功能**: 将 Claude 运行时数据从 Docker 卷复制到主机目录

```bash
docker run --rm \
    -v "${volume_name}:/source:ro" \
    -v "$target_dir:/target" \
    "$IMAGE_NAME" \
    bash -c 'rsync -av /source/ /target/'
```

**用途**:
- 备份 Claude 运行时数据
- 在不同机器间迁移数据
- 调试和检查卷内容

---

## 配置文件处理

### 1. Claude 配置文件列表

**代码位置**: `agentbox:656-666`

```bash
readonly CLAUDE_CONFIG_FILES=(
    "settings.json"
    "settings.local.json"
    ".claude.json"
    ".claude.json.backup"
    "commands"
    "ide"
    "plugins"
    "skills"
)
```

### 2. 配置文件处理策略

#### 2.1 全局配置（绑定挂载）

**位置**: `~/.claude/` 下的配置文件

**处理方式**: 直接绑定挂载到容器

**特点**:
- ✅ 实时双向同步
- ✅ 主机和容器共享同一份配置
- ✅ 修改立即生效
- ✅ 支持目录和文件

**适用场景**:
- 全局设置（settings.json）
- 认证信息（.claude.json）
- 插件和技能

#### 2.2 运行时数据（Docker 卷）

**位置**: Docker 命名卷 `agentbox-claude-<hash>`

**处理方式**: 挂载到 `/home/claude/.claude`

**特点**:
- ✅ 持久化存储
- ✅ 独立于主机文件系统
- ✅ 支持多实例（每个实例独立卷）
- ⚠️ 不直接访问，需要通过 `agentbox pull` 导出

**适用场景**:
- 会话历史
- 临时缓存
- 实例特定数据

#### 2.3 配置优先级

绑定挂载的全局配置会覆盖卷中的配置：

```
绑定挂载 > Docker 卷
```

例如，如果同时存在：
- `/home/claude/.claude/settings.json` (绑定挂载)
- 卷中的 `settings.json`

则使用绑定挂载的版本。

### 3. HOST_HOME 符号链接

**代码位置**: `entrypoint.sh:9-20`

**问题**: 配置文件可能包含主机的绝对路径（如 macOS 上的 `/Users/username/.claude/`）

**解决方案**: 创建从主机 HOME 路径到容器 HOME 的符号链接

```bash
if [ -n "$HOST_HOME" ] && [ "$HOST_HOME" != "$HOME" ]; then
    host_parent=$(dirname "$HOST_HOME")
    if [ ! -d "$host_parent" ]; then
        sudo mkdir -p "$host_parent"
    fi
    if [ ! -e "$HOST_HOME" ]; then
        sudo ln -s "$HOME" "$HOST_HOME"
    fi
fi
```

**示例**:
- 主机 HOME: `/Users/john`
- 容器 HOME: `/home/claude`
- 创建符号链接: `/Users/john` → `/home/claude`

**效果**: 配置文件中的绝对路径 `/Users/john/.claude/settings.json` 在容器内可以正常访问

### 4. .claude.json 符号链接

**代码位置**: `entrypoint.sh:22-25`

**目的**: 确保认证文件在主目录和 `.claude` 目录都可访问

```bash
if [ -f "$HOME/.claude/.claude.json" ] && [ ! -e "$HOME/.claude.json" ]; then
    ln -s "$HOME/.claude/.claude.json" "$HOME/.claude.json"
fi
```

**效果**:
- `/home/claude/.claude.json` → `/home/claude/.claude/.claude.json`
- Claude CLI 可以在两个位置找到认证文件

### 5. 环境变量设置

**代码位置**: `agentbox:465-469`

```bash
mount_opts+=(--env "CLAUDE_CONFIG_DIR=/home/claude/.claude")
mount_opts+=(--env "HOST_HOME=${HOME}")
```

**用途**:
- `CLAUDE_CONFIG_DIR`: 告诉 Claude CLI 配置目录位置
- `HOST_HOME`: 用于创建符号链接，解决绝对路径问题

---

## 容器内初始化

### 初始化步骤顺序

**脚本**: `entrypoint.sh`

1. **PATH 设置** (第 7 行)
   ```bash
   export PATH="/home/claude/.local/bin:$PATH"
   ```

2. **HOST_HOME 符号链接** (第 9-20 行)
   - 创建从主机 HOME 到容器 HOME 的符号链接
   - 解决配置文件绝对路径问题

3. **Claude 配置符号链接** (第 22-25 行)
   - 创建 `.claude.json` 符号链接

4. **NVM 初始化** (第 27-31 行)
   ```bash
   export NVM_DIR="/home/claude/.nvm"
   [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
   [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
   ```

5. **SDKMAN 初始化** (第 33-36 行)
   ```bash
   export SDKMAN_DIR="/home/claude/.sdkman"
   [[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"
   ```

6. **Python venv 自动创建** (第 38-46 行)
   - 检测 Python 项目（`requirements.txt`, `pyproject.toml`, `setup.py`）
   - 自动创建 `.venv` 虚拟环境
   ```bash
   if [ ! -d "$PWD/.venv" ] && [ -f "$PWD/requirements.txt" -o -f "$PWD/pyproject.toml" -o -f "$PWD/setup.py" ]; then
       echo "🐍 Python project detected, creating virtual environment..."
       uv venv .venv
   fi
   ```

7. **SSH 权限设置** (第 48-57 行)
   ```bash
   chmod 700 /home/claude/.ssh
   chmod 600 /home/claude/.ssh/*
   chmod 644 /home/claude/.ssh/*.pub
   chmod 644 /home/claude/.ssh/known_hosts
   ```

8. **Direnv 批准转换** (第 59-81 行)
   - 将主机的 direnv 批准记录转换为容器内的批准
   - 避免重复批准 `.envrc` 文件

9. **Git 配置设置** (第 83-95 行)
   - 从 `/tmp/host_gitconfig` 复制配置
   - 或使用默认配置

10. **MCP 检测** (第 97-100 行)
    - 检测项目是否包含 MCP 配置
    - 显示提示信息

11. **终端配置** (第 102-121 行)
    - 设置 PS1 提示符
    - 配置 shell 选项
    - 启动 Claude CLI 或执行用户命令

---

## 多实例支持

### 1. 实例命名规则

**代码位置**: `agentbox:65-70`

```bash
get_container_name() {
    local project_hash=$(echo -n "$PROJECT_DIR" | sha256sum | cut -c1-12)
    echo "${CONTAINER_PREFIX}-${project_hash}-${INSTANCE_NAME}"
}
```

**格式**: `agentbox-<project_hash>-<instance_name>`

**示例**:
- 项目: `/home/user/myproject`
- 实例 1: `agentbox-a1b2c3d4e5f6-1`
- 实例 2: `agentbox-a1b2c3d4e5f6-2`

### 2. 自动实例编号

**代码位置**: `agentbox:72-88`

**功能**: 自动分配下一个可用的实例编号

```bash
get_next_instance_number() {
    local project_hash=$(echo -n "$PROJECT_DIR" | sha256sum | cut -c1-12)
    local pattern="${CONTAINER_PREFIX}-${project_hash}-"

    # 获取所有运行的实例编号
    local used_numbers=$(docker ps --filter "name=${pattern}" --format "{{.Names}}" | \
        sed -n "s/^${pattern}\([0-9][0-9]*\)$/\1/p" | sort -n)

    # 找到第一个未使用的编号
    local num=1
    while echo "$used_numbers" | grep -q "^${num}$"; do
        ((num++))
    done

    echo "$num"
}
```

### 3. 实例隔离

每个实例拥有独立的：

| 资源 | 隔离方式 | 说明 |
|------|---------|------|
| 容器名称 | `agentbox-<hash>-<num>` | 唯一标识 |
| Claude 运行时卷 | `agentbox-claude-<hash>-<num>` | 独立的持久化数据 |
| Shell 历史 | `~/.agentbox/projects/<hash>-<num>/history` | 独立的命令历史 |

**共享资源**:
- 项目目录（同一项目的所有实例共享）
- 缓存目录（同一项目的所有实例共享）
- SSH 目录（所有实例共享）
- Claude 全局配置（所有实例共享）

### 4. 使用示例

```bash
# 启动第一个实例
cd /path/to/project
agentbox

# 在另一个终端启动第二个实例
cd /path/to/project
agentbox

# 指定实例名称
agentbox --instance dev
agentbox --instance test
```

---

## 附录：关键文件路径

| 文件 | 行数 | 主要功能 |
|------|------|---------|
| `agentbox` | 1006 | 主启动脚本，包含所有容器管理逻辑 |
| `entrypoint.sh` | 125 | 容器内初始化脚本 |
| `Dockerfile` | 211 | Docker 镜像定义 |

### 关键函数索引

| 函数 | 位置 | 功能 |
|------|------|------|
| `main()` | agentbox:816 | 主入口函数 |
| `run_container()` | agentbox:367-562 | 运行容器 |
| `mount_additional_dirs()` | agentbox:348-364 | 挂载额外目录 |
| `needs_rebuild()` | agentbox:200-221 | 检查是否需要重建镜像 |
| `build_image()` | agentbox:224-254 | 构建 Docker 镜像 |
| `ssh_setup()` | agentbox:780-813 | 设置 SSH 环境 |
| `pull_from_volume()` | agentbox:668-701 | 从卷导出数据 |
| `get_container_name()` | agentbox:65-70 | 获取容器名称 |
| `get_next_instance_number()` | agentbox:72-88 | 获取下一个实例编号 |

---

## 总结

AgentBox 的启动配置设计遵循以下原则：

1. **隔离性**: 每个项目和实例拥有独立的运行环境
2. **持久化**: 重要数据通过挂载和卷持久化存储
3. **共享性**: 全局配置和缓存在实例间共享，提高效率
4. **灵活性**: 支持多实例运行，满足不同开发场景
5. **透明性**: 配置文件实时同步，修改立即生效

通过精心设计的挂载和复制策略，AgentBox 在提供隔离环境的同时，保持了与主机系统的良好集成。
