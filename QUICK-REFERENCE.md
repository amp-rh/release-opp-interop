# Quick Reference: PR #84645 Next Steps

**Status**: Ready to implement  
**Effort**: 40 min active work + CI/review wait  

---

## The 4 Steps (Copy-Paste Ready)

### Step 1: Fix Jira Target Version ⚡
**Time**: 1 min | **Impact**: HIGH (blocking)

1. Go to: https://redhat.atlassian.net/browse/INTEROP-9447
2. Find: "Target Version" field
3. Set: Appropriate version (4.22, 5.0, 5.1, etc. based on PR scope)
4. Save

**Why**: `openshift-ci-robot` flagged missing target version as blocker.

---

### Step 2: Verify CodeRabbit Comments ✓
**Time**: 15-20 min | **Impact**: MEDIUM

1. Go to: https://github.com/openshift/release/pull/84645
2. Find: CodeRabbit's 6 review comments
3. For each comment:
   - Verify the fix is in the code
   - Reply: "✅ Fixed in commit [hash]"
4. Save

**Why**: Reviewers will spot-check fixes; make it easy for them.

---

### Step 3: Retest CI Failure 🔄
**Time**: 0 min now + wait | **Impact**: MEDIUM

Post this comment on the PR:
```
/retest ci/rehearse/periodic-ci-stolostron-policy-collection-main-ocp4.22-interop-opp-aws
```

**Result**: 
- If passes → confirmed it's a flake, proceed with merge
- If fails again → file bug against ACS/RHACS, link in PR, ask approver

**Why**: The failure is a pre-existing ACS test flake, not caused by this PR.

---

### Step 4: Request Approvals 🚀
**Time**: 1-2 min (after CI passes) | **Impact**: HIGH (required for merge)

Post comment on PR:
```
All review comments addressed ✅
CI passing ✅
Ready for /lgtm and /approve
```

Then wait for:
- `/lgtm` from a reviewer (LGTM permissions)
- `/approve` from OWNERS file approver (owns changed directories)

---

## Key Facts

| Item | Status |
|------|--------|
| Description | ✅ Already well-structured |
| File count (44) | ✅ Normal for openshift/release |
| Scope (coverage + signals) | ✅ Logically cohesive |
| CI failure | 🔄 Pre-existing flake, not PR-caused |
| Jira target version | ❌ Missing (blocking) |
| CodeRabbit comments | ✅ Resolved, need verification |

---

## Important Context (from Chai Bot)

### Why This PR is Defensible As-Is
- 44 files contains: 7 ci-operator configs, 1 generated job file, ~36 step-registry changes
- These are **tightly coupled** (not arbitrary)
- Split only if reviewer explicitly requests it
- If split needed, use Jira sub-task boundaries (9449, 9450, 9452)

### Why CI Failure Isn't Your Problem
- RHACS/ACS policy test timeout (upstream issue)
- `NullPointerException` in `PolicyService.deletePolicy` (upstream issue)
- Characteristic of ACS test flakiness
- `/retest` to confirm it's environmental, not code-related

### openshift/release Best Practices Applied
- ✅ Jira prefix in title (`INTEROP-9447:`)
- ✅ Step-registry changes called out
- ✅ Purpose statements for new steps
- ✅ Organized by Jira sub-task
- ⚠️ Missing: Jira target version (being fixed in Step 1)

---

## Files

- **This file**: Quick reference for steps
- **Implementation Plan**: `CHAI-BOT-IMPLEMENTATION-PLAN.md` (detailed)
- **Chai Bot Analysis**: `/home/amp/cursor_agent/projects/opp/.scratchpad/chai-pr-84645-review-synthesis-2026-09-08.md`
- **Pipeline Analysis**: `REVIEW-RECOMMENDATIONS.md`

---

## Done?

After all 4 steps + CI green + approvals received = **Ready to merge** ✅

Questions? See the full synthesis or reach out to Chai Bot.

