# GT2-birt

## Lokální smoke test BIRT Viewer

Předpoklady: Docker, volný port 8080.

1) Build + run + render + aserce (CSV data):

```
bash tests/scripts/local_smoke.sh
```

- Render uložen do `artifacts/rendered.html`
- V případě chyby jsou k dispozici logy v `artifacts/docker.log`

## Co dělá GitHub Actions workflow (.github/workflows/birt-smoke.yml)
- Postaví image z Dockerfile
- Spustí kontejner a vystaví port 8080
- Readiness check proti `http://localhost:8080/birt/`
- Mountne `./tests` do `/opt/tomcat/webapps/birt/tests`
- Detekuje endpoint vieweru (preview/frameset/run)
- Vyrenderuje `tests/reports/smoke.rptdesign` do HTML
- Aserce: HTTP 200, výstup > 1KB, obsahuje `SMOKE_OK` a `TOTAL=3`
- Při failu přikládá Docker logy do job summary a do artifactů

## Původní poznámky

`docker builder prune`

`az login`

`az acr login --name ekorent`

`docker build --tag=birt .`

`docker run -d -p 8080:8080 birt`

`docker rmi ekorent.azurecr.io/birt:0.0.2`

`docker tag birt ekorent.azurecr.io/birt:0.0.2`

`docker push ekorent.azurecr.io/birt:0.0.2`
