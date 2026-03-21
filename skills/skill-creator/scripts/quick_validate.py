#!/usr/bin/env python3
"""
Enhanced Skill Validator - Checks skill structure, frontmatter, and quality

Usage:
    quick_validate.py <skill_directory>
"""

import sys
import re
import yaml
from pathlib import Path

ALLOWED_PROPERTIES = {'name', 'description', 'license', 'allowed-tools', 'metadata', 'compatibility'}
MAX_DESCRIPTION_LENGTH = 1024
MAX_NAME_LENGTH = 64
MAX_BODY_LINES = 500
VAGUE_DESCRIPTIONS = [
    'helps with', 'does things', 'useful for', 'handles stuff',
    'manages tasks', 'assists with', 'provides help',
]


def validate_skill(skill_path):
    """
    Validate a skill directory. Returns (valid, messages) where messages is a list of
    (level, message) tuples. Levels: 'error', 'warning'.
    """
    skill_path = Path(skill_path)
    messages = []

    # --- Check SKILL.md exists ---
    skill_md = skill_path / 'SKILL.md'
    if not skill_md.exists():
        return False, [('error', 'SKILL.md not found')]

    content = skill_md.read_text()

    # --- Check frontmatter ---
    if not content.startswith('---'):
        return False, [('error', 'No YAML frontmatter found (must start with ---)')]

    match = re.match(r'^---\n(.*?)\n---', content, re.DOTALL)
    if not match:
        return False, [('error', 'Invalid frontmatter format (missing closing ---)')]

    frontmatter_text = match.group(1)
    body = content[match.end():]

    try:
        frontmatter = yaml.safe_load(frontmatter_text)
        if not isinstance(frontmatter, dict):
            return False, [('error', 'Frontmatter must be a YAML dictionary')]
    except yaml.YAMLError as e:
        return False, [('error', f'Invalid YAML: {e}')]

    # --- Check unexpected keys ---
    unexpected = set(frontmatter.keys()) - ALLOWED_PROPERTIES
    if unexpected:
        messages.append(('error', f"Unexpected frontmatter key(s): {', '.join(sorted(unexpected))}. Allowed: {', '.join(sorted(ALLOWED_PROPERTIES))}"))

    # --- Validate name ---
    name = frontmatter.get('name')
    if not name:
        messages.append(('error', "Missing 'name' in frontmatter"))
    elif not isinstance(name, str):
        messages.append(('error', f"Name must be a string, got {type(name).__name__}"))
    else:
        name = name.strip()
        if not re.match(r'^[a-z0-9][a-z0-9-]*[a-z0-9]$', name) and len(name) > 1:
            messages.append(('error', f"Name '{name}' must be kebab-case (lowercase, digits, hyphens, no leading/trailing hyphens)"))
        if '--' in name:
            messages.append(('error', f"Name '{name}' cannot contain consecutive hyphens"))
        if len(name) > MAX_NAME_LENGTH:
            messages.append(('error', f"Name too long ({len(name)} chars, max {MAX_NAME_LENGTH})"))

        # Check folder name matches skill name
        if skill_path.name != name:
            messages.append(('warning', f"Folder name '{skill_path.name}' doesn't match skill name '{name}'"))

    # --- Validate description ---
    description = frontmatter.get('description')
    if not description:
        messages.append(('error', "Missing 'description' in frontmatter"))
    elif not isinstance(description, str):
        messages.append(('error', f"Description must be a string, got {type(description).__name__}"))
    else:
        description = description.strip()

        if '<' in description or '>' in description:
            messages.append(('error', 'Description cannot contain XML angle brackets'))

        if len(description) > MAX_DESCRIPTION_LENGTH:
            messages.append(('error', f"Description too long ({len(description)} chars, max {MAX_DESCRIPTION_LENGTH})"))

        if len(description) < 30:
            messages.append(('warning', 'Description seems too short (under 30 chars). Include what it does AND when to use it.'))

        # Check for vague descriptions
        desc_lower = description.lower()
        for vague in VAGUE_DESCRIPTIONS:
            if desc_lower.startswith(vague) or f'. {vague}' in desc_lower:
                messages.append(('warning', f"Description may be too vague (contains '{vague}'). Be specific about what the skill does."))
                break

        # Check for trigger phrases
        trigger_keywords = ['use when', 'use for', 'trigger', 'when user', 'invoke when', 'use this']
        has_trigger = any(kw in desc_lower for kw in trigger_keywords)
        if not has_trigger:
            messages.append(('warning', "Description should include trigger conditions (e.g., 'Use when user mentions...')"))

    # --- Check for TODO remnants ---
    if '[TODO' in content or '[todo' in content.lower():
        messages.append(('warning', 'SKILL.md contains TODO placeholders - complete before publishing'))

    # --- Check body length ---
    body_lines = body.strip().split('\n')
    if len(body_lines) > MAX_BODY_LINES:
        messages.append(('warning', f"SKILL.md body is {len(body_lines)} lines (recommended max: {MAX_BODY_LINES}). Consider moving content to references/"))

    # --- Check for README.md ---
    readme = skill_path / 'README.md'
    if readme.exists():
        messages.append(('warning', "README.md found inside skill folder. Skills should not include README.md - put all docs in SKILL.md or references/"))

    # --- Check for XML angle brackets in body ---
    xml_pattern = re.compile(r'<(?!code|pre|!--|/code|/pre)[a-zA-Z]')
    if xml_pattern.search(body):
        messages.append(('warning', 'SKILL.md body may contain XML-like tags. Avoid angle brackets that could be interpreted as HTML/XML.'))

    # --- Determine overall validity ---
    errors = [m for m in messages if m[0] == 'error']
    warnings = [m for m in messages if m[0] == 'warning']

    if errors:
        return False, messages
    return True, messages


def main():
    if len(sys.argv) != 2:
        print("Usage: python quick_validate.py <skill_directory>")
        sys.exit(1)

    skill_path = sys.argv[1]
    valid, messages = validate_skill(skill_path)

    if not messages:
        print("Skill is valid!")
        sys.exit(0)

    for level, msg in messages:
        prefix = "ERROR" if level == 'error' else "WARNING"
        print(f"  [{prefix}] {msg}")

    if valid:
        print(f"\nSkill is valid with {len(messages)} warning(s).")
    else:
        errors = sum(1 for l, _ in messages if l == 'error')
        print(f"\nValidation FAILED: {errors} error(s) found.")

    sys.exit(0 if valid else 1)


if __name__ == "__main__":
    main()
