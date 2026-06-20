##############################################################################
# Outputs
##############################################################################

output "monitored_subaccounts" {
  description = "List of active subaccounts being monitored"
  value       = local.active_subaccounts
}

output "ans_api_url" {
  description = "ANS API URL being used"
  value       = var.ans_api_url
}

output "report_schedule" {
  description = "Report delivery schedule"
  value       = "Every ${var.report_interval_days} days to ${var.notification_email}"
}