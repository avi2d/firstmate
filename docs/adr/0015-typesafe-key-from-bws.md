# 0015: Typesafe dispatch key from Bitwarden Secrets Manager

Date: 2026-10-28.
Status: accepted.

## Contract

The typesafe.ai dispatch key is not stored in any .env file.
config/bws-typesafe-secret-id holds the Bitwarden Secrets Manager secret id, and its absence turns the typesafe gate off.
bin/fm-bws-lib.sh fetches the value with bws at run time, using the macOS keychain item bws-access-token and falling back to ~/.config/bws/token.
The access token reaches bws through BWS_ACCESS_TOKEN, because argv is visible to other local users.
A missing token or a failed fetch refuses with one line naming what is missing, and neither the value nor the token is printed.
