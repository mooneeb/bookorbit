# Fork Releases and Deployment

This fork ships its own container image so the server can carry fork-only features (Ink Annotations, Sketches, iPad App origin tracking) on top of upstream BookOrbit.

## Versioning

Fork releases use four-part tags: the upstream version the fork is based on, plus a fork revision.

- `v3.1.0.1` is the first fork release based on upstream `v3.1.0`.
- `v3.1.0.2` is the next fork release on the same upstream base.
- After merging upstream `v3.2.0`, the next fork release is `v3.2.0.1`.

The server's update check reads the first three parts and compares them with upstream's latest release, so a running fork still tells you when upstream has published something newer to merge.

## Publishing an image

Upstream's semantic-release workflow is guarded to the upstream repository and never runs here. Instead, `.github/workflows/fork-release.yml` runs when a four-part tag is pushed:

```bash
git tag v3.1.0.1
git push origin v3.1.0.1
```

It builds the `Dockerfile` for `linux/amd64` and `linux/arm64`, passes the tag as `APP_VERSION`, and pushes `ghcr.io/<owner>/<repo>:3.1.0.1` to this fork's GitHub Container Registry. There is no `latest` tag: deployments always pin an exact version.

Release notes are manual for now: the workflow does not create a GitHub release, so create one for the tag yourself and describe the iPad-related changes there.

GHCR packages created from a fork start private. Either make the package public (Package settings, Change visibility) or give the cluster an image pull secret for `ghcr.io`.

## Migrations

The image applies two migration sets on startup (`node dist/scripts/migrate.js`), in this order:

1. Upstream migrations, tracked in `drizzle.__drizzle_migrations`.
2. Fork migrations, tracked in `drizzle.__bookorbit_fork_migrations`.

Fork migrations only create fork-only tables that reference upstream tables by foreign key. Upstream tables are never modified. If your cluster runs migrations as a separate Job, it uses the same script and gets both sets.

## Runbook: switch the Kubernetes deployment from upstream's image to the fork's

Replace `<ns>`, `<postgres-pod>`, `<db-user>`, `<db-name>`, and `<app-deployment>` with the names in your cluster.

1. **Pick the fork release.** Its upstream base must be the same as or newer than the upstream version currently running. Never deploy a fork release based on an older upstream version than the database has already been migrated to.

2. **Back up the database first.** Take a custom-format dump and copy it off the pod:

   ```bash
   kubectl -n <ns> exec <postgres-pod> -- pg_dump -U <db-user> -d <db-name> -Fc -f /tmp/bookorbit-pre-fork.dump
   kubectl -n <ns> cp <postgres-pod>:/tmp/bookorbit-pre-fork.dump ./bookorbit-pre-fork.dump
   kubectl -n <ns> exec <postgres-pod> -- rm /tmp/bookorbit-pre-fork.dump
   ls -lh ./bookorbit-pre-fork.dump
   ```

   Do not continue unless the dump file exists and is a plausible size. Also back up the app data volume (`/data`: covers, book bucket) if your storage does not already snapshot it.

3. **Make the image pullable.** Make the GHCR package public, or create a pull secret and reference it from the deployment:

   ```bash
   kubectl -n <ns> create secret docker-registry ghcr-pull \
     --docker-server=ghcr.io --docker-username=<github-user> --docker-password=<token-with-read:packages>
   ```

4. **Switch the image.** Change the image in your manifest (or Helm values) from upstream's `ghcr.io/bookorbit/bookorbit:<version>` to `ghcr.io/<owner>/<repo>:<fork-version>` and apply it, or patch it directly:

   ```bash
   kubectl -n <ns> set image deployment/<app-deployment> '*=ghcr.io/<owner>/<repo>:3.1.0.1'
   kubectl -n <ns> rollout status deployment/<app-deployment>
   ```

   Keep all environment variables, secrets, and volumes unchanged.

5. **Verify.**

   ```bash
   kubectl -n <ns> logs deployment/<app-deployment> | grep -i migrations
   kubectl -n <ns> exec <postgres-pod> -- psql -U <db-user> -d <db-name> -c 'select count(*) from drizzle.__bookorbit_fork_migrations'
   ```

   The logs show both "Migrations applied successfully" and "Fork migrations applied successfully". In the web app, Settings shows the fork version (for example `v3.1.0.1`), and your library, reading progress, and annotations look the same as before.

6. **Roll back if needed.** Point the deployment back at upstream's image for the same upstream version. Upstream code does not read the fork tables and leaves them in place, but this path has not been exercised, and anything created on the fork (Ink Annotations, Sketches) stays invisible until you switch back. Annotations backing ink remain as ordinary Annotations. To return to the exact pre-switch state, scale the app to zero and restore the dump:

   ```bash
   kubectl -n <ns> scale deployment/<app-deployment> --replicas=0
   kubectl -n <ns> cp ./bookorbit-pre-fork.dump <postgres-pod>:/tmp/bookorbit-pre-fork.dump
   kubectl -n <ns> exec <postgres-pod> -- pg_restore -U <db-user> -d <db-name> --clean --if-exists /tmp/bookorbit-pre-fork.dump
   kubectl -n <ns> scale deployment/<app-deployment> --replicas=1
   ```
