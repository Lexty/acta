# Entry points for the companion plugins shipped alongside the app.
#
# The app itself is built with SwiftPM through Scripts/*.sh (see CLAUDE.md);
# this Makefile exists for the plugins under tools/, which are Python and have
# their own suite. Keeping the lists here is also what lets a plugin's own
# layout test assert that this repo declares it as skills-only.

# Plugins that ship a compiled binary (an MCP server or a CLI). None yet.
TOOLS =
CLI_TOOLS =
# Plugins that are skills plus bundled stdlib scripts — nothing to build.
SKILL_PLUGINS = acta-notes

.PHONY: test-skills
test-skills: ## Run the Python suite of every skills-only plugin
	@for p in $(SKILL_PLUGINS); do \
		echo "== $$p =="; \
		( cd tools/$$p && python3 -m unittest discover -s tests ) || exit 1; \
	done
