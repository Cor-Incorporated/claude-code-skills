#!/usr/bin/env python3
"""
ADK Agent Validation Script
Validates agent structure and best practices compliance.
"""

import sys
import importlib.util
from pathlib import Path
from typing import List, Tuple


class AgentValidator:
    """Validates ADK agent code for best practices."""

    def __init__(self, agent_file: Path):
        self.agent_file = agent_file
        self.warnings: List[str] = []
        self.errors: List[str] = []

    def validate(self) -> Tuple[bool, List[str], List[str]]:
        """Run all validations."""
        self._check_file_exists()
        self._check_root_agent()
        self._check_agent_structure()
        self._check_best_practices()

        success = len(self.errors) == 0
        return success, self.warnings, self.errors

    def _check_file_exists(self):
        """Check if agent file exists."""
        if not self.agent_file.exists():
            self.errors.append(f"Agent file not found: {self.agent_file}")

    def _check_root_agent(self):
        """Check if root_agent is defined."""
        try:
            spec = importlib.util.spec_from_file_location("agent", self.agent_file)
            if spec and spec.loader:
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)

                if not hasattr(module, "root_agent"):
                    self.errors.append("No 'root_agent' defined in agent file")
                    return

                root_agent = module.root_agent
                if not hasattr(root_agent, "name"):
                    self.errors.append("root_agent must have a 'name' attribute")

        except Exception as e:
            self.errors.append(f"Failed to import agent: {e}")

    def _check_agent_structure(self):
        """Check agent structure."""
        try:
            with open(self.agent_file, "r") as f:
                content = f.read()

            # Check for model specification
            if "model=" not in content:
                self.warnings.append("No explicit model specified")

            # Check for instruction
            if "instruction=" not in content:
                self.warnings.append("No instruction provided for agent")

            # Check for output_key usage
            if "output_key=" in content:
                # Good! State management is being used
                pass
            else:
                self.warnings.append(
                    "Consider using output_key for state management"
                )

        except Exception as e:
            self.errors.append(f"Failed to read agent file: {e}")

    def _check_best_practices(self):
        """Check for best practices."""
        try:
            with open(self.agent_file, "r") as f:
                content = f.read()

            # Check for max_iterations in loops
            if "LoopAgent" in content and "max_iterations=" not in content:
                self.warnings.append(
                    "LoopAgent should have max_iterations to prevent runaway costs"
                )

            # Check for agent descriptions
            if "sub_agents=" in content and "description=" not in content:
                self.warnings.append(
                    "Sub-agents should have descriptions for better routing"
                )

            # Check for unique output_keys in parallel
            if "ParallelAgent" in content:
                # This is a heuristic check
                output_keys = content.count("output_key=")
                if output_keys < 2:
                    self.warnings.append(
                        "ParallelAgent sub-agents should have unique output_keys"
                    )

        except Exception as e:
            self.errors.append(f"Failed to check best practices: {e}")


def main():
    """Main entry point."""
    if len(sys.argv) < 2:
        print("Usage: validate_agent.py <agent_file>")
        sys.exit(1)

    agent_file = Path(sys.argv[1])
    validator = AgentValidator(agent_file)
    success, warnings, errors = validator.validate()

    # Print results
    print("\n" + "=" * 60)
    print("ADK Agent Validation Report")
    print("=" * 60 + "\n")

    if errors:
        print("❌ ERRORS:")
        for error in errors:
            print(f"  • {error}")
        print()

    if warnings:
        print("⚠️  WARNINGS:")
        for warning in warnings:
            print(f"  • {warning}")
        print()

    if success and not warnings:
        print("✅ All validations passed!")
    elif success:
        print("✅ No errors found (but see warnings above)")
    else:
        print("❌ Validation failed")

    print()
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
