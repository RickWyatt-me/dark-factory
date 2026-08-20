# Deploy map — {{PROJECT_NAME}}

<!-- TEMPLATE STUB. FACTORY.md's "Deploys" section points an operator here
     mid-incident — fill it before the trigger runs deploy.sh at dial 3. -->

The full map of what `factory/deploy.sh` ships, checks, and refuses in THIS repo.

## What deploys

<!-- FILL: the deployable units (services/functions), how the script detects a
     changed unit from the merged range (the pointer diff), and where the deploy
     pointer lives. -->

## Health checks

<!-- FILL: the positive markers per unit — what "healthy" prints, where the
     script probes, timeout, and what triggers the auto-rollback. -->

## Refusals

<!-- FILL: what the script refuses and who handles each — migration-carrying
     ranges (the §2.4a road or a human), deployment-config changes, payment
     surfaces, first-time deploys. -->

## Token / auth analysis

<!-- FILL: which credential deploys ride, where it lives, when it expires, and
     the GITHUB_TOKEN caveat if any CI is involved (see FACTORY.md Standing
     caveats). -->
