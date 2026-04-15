# Bump deploy stamp

Updates `turbo.service.deployStamp` in the in-place codebase. This forces a new
service hash on deploy.

Run in-place so it can update the existing codebase:
```
ucm -c ~/.unison/v2 transcript.in-place bump-deploy-stamp.transcript.md
```

``` ucm
scratch/main> load scratch_deploy_stamp.u
scratch/main> update
```
