# Two budgets with different jobs, and the difference is which one of them sees
# credits.
#
# 1. The platform budget, filtered to this project: the ceiling from PLAN.md, per
#    calendar month. `EXCLUDE_ALL_CREDITS` is the part that matters, and it was
#    wrong here until M10 — the field "specifies how credits should be treated when
#    determining spend for threshold calculations", so the previous
#    `INCLUDE_ALL_CREDITS` meant the trial credit *subtracted* itself out of the
#    number being watched. A tripwire that measures net-of-credit spend cannot fire
#    while the credit lasts, which is precisely the period it exists to watch. This
#    budget therefore measures what the platform *costs*.
resource "google_billing_budget" "platform" {
  billing_account = var.billing_account_id
  display_name    = "learn-anything platform (this project)"

  budget_filter {
    # The project *number*, not its ID. Google answers a budget created with
    # `projects/<id>` by rewriting the filter to `projects/<number>`, so declaring
    # the ID leaves a permanent fake diff in every plan — and a plan that always
    # shows a change is a plan nobody reads.
    projects               = ["projects/${google_project.main.number}"]
    calendar_period        = "MONTH"
    credit_types_treatment = "EXCLUDE_ALL_CREDITS"
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

  # No notification rule needed for the email path: threshold alerts go to the
  # default recipients — the Billing Account Administrator and User roles on this
  # account, which is you — unless `all_updates_rule.disable_default_iam_recipients`
  # is set. Worth stating, because "no notifications_rule in the file" reads like a
  # missing feature. It was checked rather than assumed: the API returns an empty
  # `notificationsRule`, and the documented default is delivery to those roles.

  # Budgets need both the Billing Budgets API and a grant on the billing account
  # itself (see iam.tf); neither is implied by the project.
  depends_on = [google_project_service.required, google_billing_account_iam_member.terraform_local_budgets]
}

# 2. The canary: unfiltered, so it covers any project that shows up on the
#    billing account without this repo knowing about it. You confirmed this
#    project is the only consumer, so silence is the expected state; a firing
#    canary means something unknown is spending your January.
#
# It keeps `INCLUDE_ALL_CREDITS` on purpose: the canary is the wallet's question —
# *am I actually paying* — and the answer is net of credits. Two budgets, two
# bases, one fact each.
resource "google_billing_budget" "account_canary" {
  billing_account = var.billing_account_id
  display_name    = "canary: anything on this billing account outside the plan"

  depends_on = [google_project_service.required, google_billing_account_iam_member.terraform_local_budgets]

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
