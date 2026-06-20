# Orchid — standing-check entrypoints (no-AI-in-loop CI oracle wiring).
#
# `make regression` is THE standing check for the whole real-goal-closure
# capability: it runs the consolidated closure oracle through the real product
# path (GoalWatcher.runtime_planner_request -> RuntimeGoal -> Router -> planner
# -> durable sandbox), then asserts overall_pass on the emitted JSON so the
# capability cannot silently drift. Deterministic given the report; no agent in
# the loop. Requires OPENROUTER_API_KEY (free-tier nex-agi/nex-n2-pro:free is
# fine) reachable via .orchid/facts.local.json or env.
#
# NOTE: a gvr non-closure classified failure_mode=free_model_convergence_variance
# is NOT a regression (the paid-model-gated discriminator); overall_pass already
# encodes that. A flat arm <3/3 IS a real regression and fails this gate.

MIX ?= mix
REPORT := priv/autonomy/closure_regression.json

.PHONY: regression closure-flat closure-gvr regression-report deps compile

regression: ## Run the closure-regression oracle and gate on overall_pass
	$(MIX) orchid.closure_regression
	@echo "-- asserting overall_pass on $(REPORT) --"
	@test -f $(REPORT) || { echo "FAIL: $(REPORT) not emitted"; exit 1; }
	@pass=$$(jq -r '.overall_pass' $(REPORT)); \
	  flat=$$(jq -r '.flat.closed_count' $(REPORT))/$$(jq -r '.flat.total' $(REPORT)); \
	  gvr=$$(jq -r '.gvr.closed_count' $(REPORT))/$$(jq -r '.gvr.total' $(REPORT)); \
	  echo "overall_pass=$$pass flat=$$flat gvr=$$gvr"; \
	  test "$$pass" = "true" || { echo "REGRESSION: overall_pass=$$pass"; exit 1; }
	@echo "PASS: closure regression green"

closure-flat: ## Run only the flat real-goal closure harness
	$(MIX) orchid.real_goal_closure

closure-gvr: ## Run only the gvr real-goal closure harness
	$(MIX) orchid.gvr_real_goal_closure

regression-report: ## Print the last closure-regression report
	@test -f $(REPORT) && jq . $(REPORT) || echo "no report yet — run 'make regression'"

deps: ; $(MIX) deps.get
compile: ; $(MIX) compile
