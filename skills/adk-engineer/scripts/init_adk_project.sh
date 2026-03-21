#!/bin/bash
#
# ADK Project Initialization Helper
# Initializes a new ADK agent project with best practices
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if project name provided
if [ -z "$1" ]; then
    print_error "Usage: $0 <project_name> [template_type]"
    echo "  template_type: single-agent | multi-agent | workflow (default: single-agent)"
    exit 1
fi

PROJECT_NAME="$1"
TEMPLATE_TYPE="${2:-single-agent}"

# Validate template type
if [[ ! "$TEMPLATE_TYPE" =~ ^(single-agent|multi-agent|workflow)$ ]]; then
    print_error "Invalid template type. Must be: single-agent, multi-agent, or workflow"
    exit 1
fi

print_info "Initializing ADK project: $PROJECT_NAME"
print_info "Template type: $TEMPLATE_TYPE"

# Check if directory already exists
if [ -d "$PROJECT_NAME" ]; then
    print_error "Directory $PROJECT_NAME already exists"
    exit 1
fi

# Check if adk is installed
if ! command -v adk &> /dev/null; then
    print_warn "ADK CLI not found. Installing..."
    pip install google-adk
fi

# Create project directory
print_info "Creating project directory..."
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# Initialize with ADK CLI
print_info "Running adk create..."
adk create .

# Copy template files based on type
TEMPLATE_DIR="$(dirname "$0")/../assets/templates/$TEMPLATE_TYPE"
if [ -d "$TEMPLATE_DIR" ]; then
    print_info "Copying $TEMPLATE_TYPE template files..."
    cp -r "$TEMPLATE_DIR"/* .
fi

# Create additional project structure
print_info "Creating project structure..."
mkdir -p tests
mkdir -p config
mkdir -p tools
mkdir -p agents

# Create .gitignore
cat > .gitignore << 'EOF'
# Python
__pycache__/
*.py[cod]
*$py.class
*.so
.Python
env/
venv/
ENV/

# Environment
.env
.env.local

# IDE
.vscode/
.idea/
*.swp
*.swo

# ADK
.adk_cache/

# OS
.DS_Store
Thumbs.db
EOF

# Create basic test file
cat > tests/test_agent.py << 'EOF'
"""Tests for the agent."""

import pytest


def test_agent_exists():
    """Test that the agent can be imported."""
    from agent import root_agent

    assert root_agent is not None
    assert root_agent.name is not None
EOF

print_info "Creating virtual environment..."
python -m venv venv

print_info "Installing dependencies..."
source venv/bin/activate
pip install -r requirements.txt
pip install pytest

print_success() {
    echo ""
    print_info "${GREEN}✓${NC} Project initialized successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. cd $PROJECT_NAME"
    echo "  2. source venv/bin/activate"
    echo "  3. Set GOOGLE_AI_API_KEY environment variable"
    echo "  4. python agent.py (CLI mode)"
    echo "  5. adk ui --agent-file agent.py (Web UI mode)"
    echo ""
}

print_success
