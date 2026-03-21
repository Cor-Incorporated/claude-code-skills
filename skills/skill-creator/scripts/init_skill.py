#!/usr/bin/env python3
"""
Skill Initializer - Creates a new skill from template

Usage:
    init_skill.py <skill-name> --path <path>

Examples:
    init_skill.py my-new-skill --path skills/public
    init_skill.py my-api-helper --path ~/.claude/skills
"""

import sys
from pathlib import Path


SKILL_TEMPLATE = """---
name: {skill_name}
description: |
  [TODO: Write description following this structure]
  [What it does]. Use when user [specific trigger phrases].
  Do NOT use for [negative triggers].
---

# {skill_title}

[TODO: 1-2 sentences explaining what this skill enables]

## Instructions

### Step 1: [First Major Step]
[Clear explanation of what happens]

### Step 2: [Second Major Step]
[Clear explanation of what happens]

## Error Handling

### [Common Error]
If you see "[error message]":
1. [First fix step]
2. [Second fix step]

## Resources

- **scripts/**: [Describe available scripts and when to use them]
- **references/**: [Describe reference docs and when to consult them]

Delete any resource directories not needed for this skill.
"""


def title_case_skill_name(skill_name):
    """Convert hyphenated skill name to Title Case."""
    return ' '.join(word.capitalize() for word in skill_name.split('-'))


def init_skill(skill_name, path):
    """Initialize a new skill directory with template SKILL.md."""
    skill_dir = Path(path).resolve() / skill_name

    if skill_dir.exists():
        print(f"Error: Skill directory already exists: {skill_dir}")
        return None

    try:
        skill_dir.mkdir(parents=True, exist_ok=False)
    except Exception as e:
        print(f"Error creating directory: {e}")
        return None

    # Create SKILL.md
    skill_title = title_case_skill_name(skill_name)
    content = SKILL_TEMPLATE.format(skill_name=skill_name, skill_title=skill_title)
    (skill_dir / 'SKILL.md').write_text(content)
    print(f"Created: {skill_dir}/SKILL.md")

    # Create resource directories
    for subdir in ['scripts', 'references', 'assets']:
        (skill_dir / subdir).mkdir(exist_ok=True)

    print(f"\nSkill '{skill_name}' initialized at {skill_dir}")
    print("\nNext steps:")
    print("1. Edit SKILL.md - complete TODO items and write description")
    print("2. Add scripts/references/assets as needed")
    print("3. Delete unused resource directories")
    print("4. Run package_skill.py when ready")

    return skill_dir


def main():
    if len(sys.argv) < 4 or sys.argv[2] != '--path':
        print("Usage: init_skill.py <skill-name> --path <path>")
        print("\nSkill name: kebab-case, lowercase, max 40 chars")
        print("\nExamples:")
        print("  init_skill.py my-new-skill --path ~/.claude/skills")
        print("  init_skill.py data-analyzer --path ./skills")
        sys.exit(1)

    result = init_skill(sys.argv[1], sys.argv[3])
    sys.exit(0 if result else 1)


if __name__ == "__main__":
    main()
