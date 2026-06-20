##############################################################################
# Variables
##############################################################################

variable "global_account_subdomain" {
  description = "SAP BTP Global Account subdomain"
  type        = string
}

variable "btp_username" {
  description = "BTP platform user email"
  type        = string
  sensitive   = true
}

variable "btp_password" {
  description = "BTP platform user password"
  type        = string
  sensitive   = true
}

variable "notification_email" {
  description = "Email address to receive the 7-day quota report"
  type        = string
}

variable "cf_api_endpoint" {
  description = "Default CF API endpoint (region-specific)"
  type        = string
  default     = "https://api.cf.us10.hana.ondemand.com"
}

variable "report_interval_days" {
  description = "How often to send the quota report (in days)"
  type        = number
  default     = 7
}

# ---------- ANS Credentials (from existing CF service key) ----------

variable "ans_client_id" {
  description = "ANS OAuth client ID (from service key: client_id)"
  type        = string
  sensitive   = true
}

variable "ans_client_secret" {
  description = "ANS OAuth client secret (from service key: client_secret)"
  type        = string
  sensitive   = true
}

variable "ans_uaa_url" {
  description = "ANS UAA base URL for OAuth (from service key: oauth_url, without /oauth/token path)"
  type        = string
}

variable "ans_api_url" {
  description = "ANS API URL for sending events (from service key: url)"
  type        = string
}