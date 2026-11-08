# What the identity suites expect a data folder to produce. Sourced by bash, and paired
# with a data folder: IDENTITY_DIR names the folder, IDENTITY_EXPECTED names a file like
# this one, so the same assertions can run against other data.

# The four cases the suites stage.
MAIN=alice       # the main account, which plain github.com logs in as
ORG=acme         # an organization sharing MAIN's key, with its own identity
SECOND=bob       # a separate account with its own key
ABSENT=carol     # a declared account that a machine may not have

# One line per owner: owner|name|email|account whose key signs|SSH alias
EXPECTED_IDENTITIES="alice|Alice|1001+alice@users.noreply.github.com|alice|github-alice
acme|Alice Example|alice@acme.example|alice|github-alice
bob|Bob|1002+bob@users.noreply.github.com|bob|github-bob
carol|carol|1003+carol@users.noreply.github.com|carol|github-carol"
