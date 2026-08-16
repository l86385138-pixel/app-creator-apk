#!/usr/bin/env bash
set -euo pipefail
: "${SUPABASE_URL:?SUPABASE_URL secret is required}"
: "${SUPABASE_SERVICE_ROLE_KEY:?SUPABASE_SERVICE_ROLE_KEY secret is required}"
api="$SUPABASE_URL/rest/v1"
CURL_CFG=$(mktemp)
cat > "$CURL_CFG" <<EOF
--header
apikey: $SUPABASE_SERVICE_ROLE_KEY
--header
Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY
--header
Content-Type: application/json
--header
Prefer: return=representation
EOF
cleanup(){ rm -f "$CURL_CFG" "$CURL_CFG.body" "$project_file" "$logo_file" "$logo_tmp"; }
trap cleanup EXIT
api_get(){ curl --fail --silent --show-error --config "$CURL_CFG" --url "$1"; }
api_patch(){ local url="$1" body="$2"; printf '%s' "$body" > "$CURL_CFG.body"; curl --fail --silent --show-error --request PATCH --config "$CURL_CFG" --data-binary @"$CURL_CFG.body" --url "$url"; rm -f "$CURL_CFG.body"; }
BUILD_ID=''; PROJECT_ID=''
fail_build(){ rc=$?; if [ -n "${BUILD_ID:-}" ]; then printf '%s' "{\"status\":\"failed\",\"build_log\":\"worker failed with exit code $rc\"}" > "$CURL_CFG.body"; curl --silent --show-error --request PATCH --config "$CURL_CFG" --data-binary @"$CURL_CFG.body" --url "$api/app_creator_builds?id=eq.$BUILD_ID" >/dev/null || true; rm -f "$CURL_CFG.body"; fi; exit "$rc"; }
trap fail_build ERR
if [ -n "${BUILD_ID_OVERRIDE:-}" ]; then
  BUILD_ID="$BUILD_ID_OVERRIDE"
elif [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ]; then
  BUILD_ID=$(python3 - "$GITHUB_EVENT_PATH" <<'PY'
import json,sys
try: print((json.load(open(sys.argv[1])).get('client_payload') or {}).get('build_id') or '')
except Exception: print('')
PY
)
fi
if [ -n "$BUILD_ID" ]; then
  row=$(api_get "$api/app_creator_builds?select=id,project_id,status,created_at&id=eq.$BUILD_ID&limit=1")
else
  cutoff=$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  stale=$(api_get "$api/app_creator_builds?select=id&status=eq.building&created_at=lt.$cutoff&order=created_at.asc&limit=1") || stale='[]'
  if [ "$stale" != "[]" ]; then
    sid=$(python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["id"])' <<<"$stale")
    api_patch "$api/app_creator_builds?id=eq.$sid&status=eq.building" '{"status":"queued"}' >/dev/null || true
  fi
  row=$(api_get "$api/app_creator_builds?select=id,project_id,status,created_at&status=eq.queued&order=created_at.asc&limit=1")
fi
[ "$row" != "[]" ] || { echo 'No queued build found'; exit 0; }
BUILD_ID=$(python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["id"])' <<<"$row")
PROJECT_ID=$(python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["project_id"])' <<<"$row")
project_file=$(mktemp)
logo_file=$(mktemp)
logo_tmp=$(mktemp)
api_get "$api/app_creator_projects?select=id,slug,name,target_url&id=eq.$PROJECT_ID&limit=1" > "$project_file"
[ "$(cat "$project_file")" != "[]" ] || { echo "Project not found: $PROJECT_ID"; exit 1; }
api_get "$api/app_creator_projects?select=logo_data&id=eq.$PROJECT_ID&limit=1" > "$logo_file"
export APP_NAME=$(python3 - "$project_file" <<'PY'
import json,sys; print(json.load(open(sys.argv[1]))[0]["name"])
PY
)
export SLUG=$(python3 - "$project_file" <<'PY'
import json,sys; print(json.load(open(sys.argv[1]))[0]["slug"])
PY
)
export TARGET_URL=$(python3 - "$project_file" <<'PY'
import json,sys; print(json.load(open(sys.argv[1]))[0]["target_url"])
PY
)
# Copy the logo directly file-to-file; never store a large base64 logo in a shell argument.
python3 - "$logo_file" "$logo_tmp" <<'PY'
import json,sys,pathlib
p=json.load(open(sys.argv[1])); logo=(p[0].get('logo_data') or '') if p else ''
pathlib.Path(sys.argv[2]).write_text(logo)
PY
api_patch "$api/app_creator_builds?id=eq.$BUILD_ID" '{"status":"building"}' >/dev/null
rm -f app-release.apk app-release-aligned.apk release-key.jks badging.txt
root=buildapp; rm -rf "$root"; mkdir -p "$root/app/src/main/java/com/appcreator" "$root/app/src/main/res/values" "$root/app/src/main/res/drawable" "$root/app/src/main/res/drawable-nodpi"
# Stable Android package: based only on immutable project UUID, never on editable app name/slug.
project_hex=$(printf '%s' "$PROJECT_ID" | tr -d '-')
package_suffix=$(printf '%s' "$project_hex" | cut -c1-16); package_suffix=${package_suffix:-app}
cat > "$root/settings.gradle" <<'EOF'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS); repositories { google(); mavenCentral() } }
rootProject.name='AppCreatorBuild'; include ':app'
EOF
cat > "$root/build.gradle" <<'EOF'
plugins { id 'com.android.application' version '8.6.1' apply false }
EOF
cat > "$root/app/build.gradle" <<EOF
plugins { id 'com.android.application' }
android { namespace 'com.appcreator'; compileSdk 35
 defaultConfig { applicationId "com.appcreator.$package_suffix"; minSdk 23; targetSdk 35; versionCode 1; versionName '1.0' }
}
EOF
python3 - "$logo_tmp" <<'PY'
import sys,base64,pathlib,html,os
r=pathlib.Path('buildapp'); n=html.escape(os.environ['APP_NAME'],quote=True); u=os.environ['TARGET_URL'].replace('\\','\\\\').replace('"','\\"')
(r/'app/src/main/res/values/strings.xml').write_text(f'<resources><string name="app_name">{n}</string></resources>')
(r/'app/src/main/res/values/styles.xml').write_text('<resources><style name="AppTheme" parent="style/Theme.Material.Light.NoActionBar"/></resources>')
logo=pathlib.Path(sys.argv[1]).read_text(); ext=''
if logo.startswith('data:image/') and ';base64,' in logo:
 m,data=logo.split(';base64,',1); ext='png' if 'png' in m else ('webp' if 'webp' in m else 'jpg')
 pathlib.Path(r/f'app/src/main/res/drawable-nodpi/app_logo.{ext}').write_bytes(base64.b64decode(data)); icon='@drawable/app_logo'
else:
 (r/'app/src/main/res/drawable/app_logo.xml').write_text('<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="48dp" android:height="48dp" android:viewportWidth="48" android:viewportHeight="48"><path android:fillColor="#087F5B" android:pathData="M24,4A20,20 0,1 0,24 44A20,20 0,1 0,24 4M24,10A14,14 0,1 1,24 38A14,14 0,1 1,24 10"/></vector>'); icon='@drawable/app_logo'
(r/'app/src/main/AndroidManifest.xml').write_text(f'<manifest xmlns:android="http://schemas.android.com/apk/res/android"><uses-permission android:name="android.permission.INTERNET"/><application android:theme="@style/AppTheme" android:label="@string/app_name" android:icon="{icon}"><activity android:name=".MainActivity" android:exported="true"><intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter></activity></application></manifest>')
java='package com.appcreator; import android.app.*; import android.os.*; import android.graphics.Color; import android.webkit.*; import android.widget.*; public class MainActivity extends Activity { public void onCreate(Bundle b){super.onCreate(b); LinearLayout r=new LinearLayout(this);r.setOrientation(LinearLayout.VERTICAL); TextView t=new TextView(this);t.setText(R.string.app_name);t.setTextColor(Color.WHITE);t.setTextSize(19);t.setPadding(16,8,8,8);t.setBackgroundColor(Color.rgb(23,32,51));r.addView(t);'
if ext: java+='ImageView logo=new ImageView(this); logo.setImageResource(com.appcreator.R.drawable.app_logo); logo.setAdjustViewBounds(true); logo.setPadding(12,12,12,12); r.addView(logo,new LinearLayout.LayoutParams(-1,100));'
java+='WebView w=new WebView(this);w.getSettings().setJavaScriptEnabled(true);w.getSettings().setDomStorageEnabled(true);w.setWebViewClient(new WebViewClient());w.loadUrl("'+u+'");r.addView(w,new LinearLayout.LayoutParams(-1,0,1));setContentView(r);}}'
(r/'app/src/main/java/com/appcreator/MainActivity.java').write_text(java)
PY
(cd "$root" && gradle --build-cache assembleRelease)
APK=$(find "$root/app/build/outputs/apk/release" -name '*.apk'|head -1); [ -s "$APK" ] || { echo 'Release APK was not produced'; exit 1; }
BT="${ANDROID_BUILD_TOOLS:-$ANDROID_HOME/build-tools/$(ls "$ANDROID_HOME/build-tools"|sort -V|tail -1)}"
KEYSTORE_PASSWORD="${APK_KEYSTORE_PASSWORD:-AppCreatorRelease2026!}"; KEY_PASSWORD="${APK_KEY_PASSWORD:-$KEYSTORE_PASSWORD}"; KEY_ALIAS="${APK_KEY_ALIAS:-appcreator}"; export KEYSTORE_PASSWORD KEY_PASSWORD
keytool -genkeypair -keystore release-key.jks -storepass "$KEYSTORE_PASSWORD" -keypass "$KEY_PASSWORD" -alias "$KEY_ALIAS" -keyalg RSA -keysize 2048 -validity 10000 -dname 'CN=App Creator,O=App Creator,C=IN' -noprompt >/dev/null
"$BT/zipalign" -f -p 4 "$APK" app-release-aligned.apk
"$BT/apksigner" sign --ks release-key.jks --ks-pass env:KEYSTORE_PASSWORD --key-pass env:KEY_PASSWORD --ks-key-alias "$KEY_ALIAS" --out app-release.apk app-release-aligned.apk
"$BT/zipalign" -c -v 4 app-release.apk
"$BT/apksigner" verify --verbose app-release.apk
"$BT/aapt2" dump badging app-release.apk | tee badging.txt
grep -Fq "application-label:'$APP_NAME'" badging.txt
TAG="build-$BUILD_ID"; URL="https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/app-release.apk"; export GH_TOKEN="$GITHUB_TOKEN"
gh release create "$TAG" app-release.apk --repo "$GITHUB_REPOSITORY" --title "$APP_NAME APK" --notes 'Verified signed APK' --latest=false
echo "APK_RELEASE_URL=$URL"
printf '%s' "{\"apk_url\":\"$URL\"}" > "$CURL_CFG.body"; curl --fail --silent --show-error --request PATCH --config "$CURL_CFG" --data-binary @"$CURL_CFG.body" --url "$api/app_creator_projects?id=eq.$PROJECT_ID" >/dev/null; rm -f "$CURL_CFG.body"
printf '%s' "{\"status\":\"ready\",\"apk_path\":\"$URL\"}" > "$CURL_CFG.body"; curl --fail --silent --show-error --request PATCH --config "$CURL_CFG" --data-binary @"$CURL_CFG.body" --url "$api/app_creator_builds?id=eq.$BUILD_ID" >/dev/null; rm -f "$CURL_CFG.body"
trap - ERR