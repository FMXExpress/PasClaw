#!/bin/bash
# setup_cog.sh - Prepares the cog build directory by copying local source folders.
# This ensures Cog's Docker context has access to the codebase for compilation.

set -e

# Change directory to where setup_cog.sh is located
cd "$(dirname "$0")"

echo "🧹 Cleaning previous build assets..."
rm -rf src Makefile samples

echo "📂 Copying codebase to build context..."
cp -R ../src ./src
cp ../Makefile ./Makefile

echo "✨ Ready! You can now run:"
echo "   cog build"
echo "   cog predict -i message=\"hello\" -i openai_api_key=\"sk-...\""
