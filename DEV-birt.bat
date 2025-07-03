echo off

if [%1]==[] (
  for /f "delims=" %%x in (version.txt) do set ver=%%x
  if [%ver]==[] (
    echo No version as parameter found, deploy failed
    goto END
  )
) else (
  set ver=%1%
)

call docker version
if [%errorlevel%]==[1] (	
  echo Docker engine not found, deploy failed
  goto END
) 

::pull from GIT repo
::echo on
::git.exe -c fetch.parallel=0 -c submodule.fetchJobs=0 pull --progress "origin" +refs/heads/master
::echo off

SET /P AREYOUSURE=Deploy GT2Birt.%ver% to Creditshare DEV, continue (Y/[N])?
IF /I "%AREYOUSURE%" NEQ "Y" goto END

::clear cache
::call docker builder prune

::login to Azure
call az login --tenant jardapangmail.onmicrosoft.com

::login to Docker
call az acr login --name creditshare

::BUILD
call docker build --tag birt .

::TAG the build
call docker tag birt creditshare.azurecr.io/birt:%ver%

::DEPLOY
call docker push creditshare.azurecr.io/birt:%ver%

echo Deploy GT2Birt.%ver% successful!
echo (you must set a new revision on Azure Portal)

:END
set ver=
pause
