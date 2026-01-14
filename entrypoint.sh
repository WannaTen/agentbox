#!/bin/bash
# AgentBox entrypoint script - minimal initialization

set -e

# Ensure proper PATH
export PATH="$HOME/.local/bin:$PATH"

# Create symlink from host HOME path to container HOME for config file compatibility
# Config files may contain absolute paths like /Users/john/.claude/ which need to work in container
if [ -n "$HOST_HOME" ] && [ "$HOST_HOME" != "$HOME" ]; then
    host_parent=$(dirname "$HOST_HOME")
    if [ ! -d "$host_parent" ]; then
        sudo mkdir -p "$host_parent"
    fi
    if [ ! -e "$HOST_HOME" ]; then
        sudo ln -s "$HOME" "$HOST_HOME"
        echo "✅ Created symlink: $HOST_HOME -> $HOME"
    fi
fi

# Symlink .claude.json from volume to home directory for persistence
if [ -f "$HOME/.claude/.claude.json" ] && [ ! -e "$HOME/.claude.json" ]; then
    ln -s "$HOME/.claude/.claude.json" "$HOME/.claude.json"
fi

# Ensure hasCompletedOnboarding is set to true in .claude.json
CLAUDE_JSON="$HOME/.claude/.claude.json"
if [ -f "$CLAUDE_JSON" ]; then
    # File exists, check if hasCompletedOnboarding is already true
    current_value=$(jq -r '.hasCompletedOnboarding // false' "$CLAUDE_JSON" 2>/dev/null)
    if [ "$current_value" != "true" ]; then
        # Update or add the field
        jq '. + {"hasCompletedOnboarding": true}' "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" && \
            mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
        echo "✅ Set hasCompletedOnboarding to true"
    fi
elif [ -d "$HOME/.claude" ]; then
    # Directory exists but file doesn't, create new file
    echo '{"hasCompletedOnboarding": true}' > "$CLAUDE_JSON"
    echo "✅ Created .claude.json with hasCompletedOnboarding"
fi

# Source NVM if available
if [ -s "$HOME/.nvm/nvm.sh" ]; then
    export NVM_DIR="$HOME/.nvm"
    source "$NVM_DIR/nvm.sh"
fi

# Source SDKMAN if available
if [ -f "$HOME/.sdkman/bin/sdkman-init.sh" ]; then
    source "$HOME/.sdkman/bin/sdkman-init.sh"
fi

# Create Python virtual environment if it doesn't exist in the project
# Use PWD which is set by docker run -w flag
if [ ! -d "$PWD/.venv" ] && [ -f "$PWD/requirements.txt" -o -f "$PWD/pyproject.toml" -o -f "$PWD/setup.py" ]; then
    echo "🐍 Python project detected, creating virtual environment..."
    cd "$PWD"
    uv venv .venv
    echo "✅ Virtual environment created at .venv/"
    echo "   Activate with: source .venv/bin/activate"
fi

# Set proper permissions on mounted SSH directory if it exists
if [ -d "/home/claude/.ssh" ]; then
    # Ensure correct permissions for SSH directory and files
    chmod 700 /home/claude/.ssh 2>/dev/null || true
    chmod 600 /home/claude/.ssh/* 2>/dev/null || true
    chmod 644 /home/claude/.ssh/*.pub 2>/dev/null || true
    chmod 644 /home/claude/.ssh/authorized_keys 2>/dev/null || true
    chmod 644 /home/claude/.ssh/known_hosts 2>/dev/null || true
    echo "✅ SSH directory permissions configured"
fi

# Translate host direnv approvals to container paths
if [ -d "/tmp/host_direnv_allow" ] && [ -f "$PWD/.envrc" ] && [ -n "$HOST_PROJECT_DIR" ]; then
    mkdir -p /home/claude/.local/share/direnv/allow

    # The host .envrc path
    host_envrc_path="$HOST_PROJECT_DIR/.envrc"
    # Container .envrc path
    container_envrc_path="$PWD/.envrc"

    # Calculate the expected hash for the host path + current .envrc content
    # This is how direnv validates approvals
    expected_host_hash=$(printf "%s\n" "$host_envrc_path" | cat - "$container_envrc_path" | sha256sum | cut -d' ' -f1)

    # If a valid approval exists for the current .envrc content, create a corresponding approval in the container
    if [ -f "/tmp/host_direnv_allow/$expected_host_hash" ]; then
        approved_path=$(cat "/tmp/host_direnv_allow/$expected_host_hash")
        if [ "$approved_path" = "$host_envrc_path" ]; then
            container_hash=$(printf "%s\n" "$container_envrc_path" | cat - "$container_envrc_path" | sha256sum | cut -d' ' -f1)
            echo "$container_envrc_path" > /home/claude/.local/share/direnv/allow/"$container_hash"
            echo "✅ Translated direnv approval from host to container"
        fi
    fi
fi

# Set up git config for commits inside container
if [ -f "/tmp/host_gitconfig" ]; then
    cp /tmp/host_gitconfig /home/claude/.gitconfig
else
    cat > /home/claude/.gitconfig << 'EOF'
[user]
    email = claude@agentbox
    name = Claude (AgentBox)
[init]
    defaultBranch = main
EOF
    echo "ℹ️  Using default git identity (claude@agentbox). Configure ~/.gitconfig on host to customize."
fi

# Check if project has MCP servers and show reminder
if [ -f "$PWD/.mcp.json" ] || [ -f "$PWD/mcp.json" ]; then
    echo "🔌 MCP configuration detected. To enable MCP servers, see AgentBox documentation."
fi

# Set terminal for better experience
export TERM=xterm-256color

# Handle terminal size
if [ -t 0 ]; then
    # Update terminal size
    eval $(resize 2>/dev/null || true)
fi

# If running interactively, show welcome message
if [ -t 0 ] && [ -t 1 ]; then
    echo "🤖 AgentBox Development Environment"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📁 Project Directory: $PWD"
    echo "🐍 Python: $(python3 --version 2>&1 | cut -d' ' -f2) (uv available)"
    echo "🟢 Node.js: $(node --version 2>/dev/null || echo 'not found')"
    echo "🤖 Claude CLI: $(claude --version 2>/dev/null || echo 'not found - check installation')"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
fi

# Execute the command passed to docker run
exec "$@"
