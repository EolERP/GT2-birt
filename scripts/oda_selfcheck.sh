#!/usr/bin/env bash
# Read-only startup self-check for ODA-related jars
set -euo pipefail

prefix="[oda-selfcheck]"
search_dirs=(
  "/opt/tomcat/webapps/birt/WEB-INF/lib"
  "/opt/tomcat/webapps/birt/WEB-INF/platform/plugins"
  "/opt/tomcat/webapps/birt-runtime/ReportEngine/addons"
  "/opt/tomcat/webapps/birt-runtime/ReportEngine/plugins"
)
patterns=(
  "org.eclipse.datatools.enablement.oda.xml_*.jar"
  "org.eclipse.datatools.enablement.oda.flatfile_*.jar"
)

echo "$prefix scanning for ODA jars..."
for d in "${search_dirs[@]}"; do
  if [[ -d "$d" ]]; then
    for pat in "${patterns[@]}"; do
      # list only immediate files to keep output concise
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        echo "$prefix $d -> $(basename "$f")"
      done < <(find "$d" -maxdepth 1 -type f -name "$pat" 2>/dev/null | sort || true)
    done
  fi
done

echo "$prefix done"
