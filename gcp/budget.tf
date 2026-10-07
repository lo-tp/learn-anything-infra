# Two budgets with different jobs.
#
# 1. The platform budget, filtered to this project: the ceiling from PLAN.md, per
#    calendar month. INCLUDE_ALL_CREDITS is the part that matters — while the
#    trial credit hides the cost on the bill, this budget still measures real
#    consumption, which is the only way the 90-day constraint is observable
#    before it becomes an invoice.
resource "google_billing_budget" "platform" {
  billing_account = var.billing_account_id
  display_name    = "learn-anything platform (this project)"

  budget_filter {
    projects               = ["projects/${var.project_id}"]
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      units = floor(var.monthly_platform_budget_usd)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }

  threshold_rules {
    threshold_percent = 0.75
  }

  # The last alert is a forecast, not a bill: it fires when the month *is going
  # to* overrun, which is a day or two earlier than the thing you can act on.
  threshold_rules {
    threshold_percent = 1
    spend_basis       = "FORECASTED_SPEND"
  }

  # No all_updates_rule: default recipients are the Billing Account Users and
  # Administrators, and on this account that is you.
}

# 2. The canary: unfiltered, so it covers any project that shows up on the
#    billing account without this repo knowing about it. You confirmed this
#    project is the only consumer, so silence is the expected state; a firing
#    canary means something unknown is spending your January.
resource "google_billing_budget" "account_canary" {
  billing_account = var.billing_account_id
  display_name    = "canary: anything on this billing account outside the plan"

  budget_filter {
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      units = floor(var.monthly_platform_budget_usd)
    }
  }

  threshold_rules {
    threshold_percent = 1.5
  }
}
