#!/usr/bin/env bash
set -Eeuo pipefail
: "${WORKER_API_URL:?WORKER_API_URL is required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
CURL_CFG=$(mktemp); project_file=$(mktemp); logo_tmp=$(mktemp); response_file=$(mktemp)
BUILD_ID=''; PROJECT_ID=''; STEP='startup'; FINAL_SENT=0
cleanup(){ rm -f "$CURL_CFG" "$CURL_CFG.body" "$project_file" "$logo_tmp" "$response_file"; }
trap cleanup EXIT
cat > "$CURL_CFG" <<EOF
--header
Authorization: Bearer $GITHUB_TOKEN
--header
Content-Type: application/json
--header
Accept: application/json
EOF
worker(){ local body="$1"; printf '%s' "$body" > "$CURL_CFG.body"; curl --fail --silent --show-error --connect-timeout 10 --max-time 30 --request POST --config "$CURL_CFG" --data-binary @"$CURL_CFG.body" --url "$WORKER_API_URL"; rm -f "$CURL_CFG.body"; }
finish_status(){ local status="$1"; local log="$2"; if [ -n "$BUILD_ID" ] && [ "$FINAL_SENT" = 0 ]; then FINAL_SENT=1; python3 - "$BUILD_ID" "$PROJECT_ID" "$status" "$log" <<'PY' | worker
import json,sys
build_id,project_id,status,log=sys.argv[1:]
print(json.dumps({'action':'status','build_id':build_id,'project_id':project_id,'status':status,'build_log':log[:4000]}))
PY
 fi }
on_error(){ rc=$?; set +e; finish_status failed "Build failed at step: ${STEP}; exit code: ${rc}" >/dev/null 2>&1 || true; exit "$rc"; }
trap on_error ERR
STEP='claim'; worker '{"action":"next"}' > "$response_file"
HAS_BUILD=$(python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("build") else "0")' < "$response_file")
if [ "$HAS_BUILD" = "1" ]; then
 BUILD_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["build"]["id"])' < "$response_file")
 PROJECT_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["build"]["project_id"])' < "$response_file")
else
 STEP='recover'; RECOVER=$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 --request POST --config "$CURL_CFG" --data '{"action":"recover"}' --url "$WORKER_API_URL")
 HAS_RECOVER=$(printf '%s' "$RECOVER" | python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("build") else "0")')
 if [ "$HAS_RECOVER" != "1" ]; then echo 'No queued or recoverable build found'; exit 0; fi
 BUILD_ID=$(printf '%s' "$RECOVER" | python3 -c 'import json,sys; print(json.load(sys.stdin)["build"]["id"])')
 PROJECT_ID=$(printf '%s' "$RECOVER" | python3 -c 'import json,sys; print(json.load(sys.stdin)["build"]["project_id"])')
fi
STEP='project'; worker "{\"action\":\"project\",\"project_id\":\"$PROJECT_ID\"}" > "$project_file"
export APP_NAME=$(python3 - "$project_file" <<'PY'
import json,sys; print(json.load(open(sys.argv[1]))['project']['name'])
PY
)
export SLUG=$(python3 - "$project_file" <<'PY'
import json,sys; print(json.load(open(sys.argv[1]))['project']['slug'])
PY
)
export TARGET_URL=$(python3 - "$project_file" <<'PY'
import json,sys; print(json.load(open(sys.argv[1]))['project']['target_url'])
PY
)
python3 - "$project_file" "$logo_tmp" <<'PY'
import json,sys,pathlib
p=json.load(open(sys.argv[1]))['project']; pathlib.Path(sys.argv[2]).write_text(p.get('logo_data') or '')
PY
STEP='mark-building'; worker "{\"action\":\"status\",\"build_id\":\"$BUILD_ID\",\"project_id\":\"$PROJECT_ID\",\"status\":\"building\"}" >/dev/null
rm -f app-release.apk app-release-aligned.apk release-key.jks badging.txt
STEP='generate-project'; root=buildapp; rm -rf "$root"; mkdir -p "$root/app/src/main/java/com/appcreator" "$root/app/src/main/res/values" "$root/app/src/main/res/drawable" "$root/app/src/main/res/drawable-nodpi"
project_hex=$(printf '%s' "$PROJECT_ID" | tr -d '-'); package_suffix="p$(printf '%s' "$project_hex" | cut -c1-15)"; package_suffix=${package_suffix:-papp}
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
(r/'app/src/main/res/values/styles.xml').write_text('<resources><style name="AppTheme" parent="android:style/Theme.Material.Light.NoActionBar"/></resources>')
logo=pathlib.Path(sys.argv[1]).read_text(); ext=''
if logo.startswith('data:image/') and ';base64,' in logo:
 m,data=logo.split(';base64,',1); ext='png' if 'png' in m else ('webp' if 'webp' in m else 'jpg'); pathlib.Path(r/f'app/src/main/res/drawable-nodpi/app_logo.{ext}').write_bytes(base64.b64decode(data)); icon='@drawable/app_logo'
else:
 (r/'app/src/main/res/drawable/app_logo.xml').write_text('<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="48dp" android:height="48dp" android:viewportWidth="48" android:viewportHeight="48"><path android:fillColor="#087F5B" android:pathData="M24,4A20,20 0,1 0,24 44A20,20 0,1 0,24 4M24,10A14,14 0,1 1,24 38A14,14 0,1 1,24 10"/></vector>'); icon='@drawable/app_logo'
(r/'app/src/main/AndroidManifest.xml').write_text(f'<manifest xmlns:android="http://schemas.android.com/apk/res/android"><uses-permission android:name="android.permission.INTERNET"/><application android:theme="@style/AppTheme" android:label="@string/app_name" android:icon="{icon}"><activity android:name=".MainActivity" android:exported="true"><intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter></activity></application></manifest>')
java='package com.appcreator; import android.app.*; import android.os.*; import android.graphics.Color; import android.webkit.*; import android.widget.*; public class MainActivity extends Activity { public void onCreate(Bundle b){super.onCreate(b); LinearLayout r=new LinearLayout(this);r.setOrientation(LinearLayout.VERTICAL); TextView t=new TextView(this);t.setText(R.string.app_name);t.setTextColor(Color.WHITE);t.setTextSize(19);t.setPadding(16,8,8,8);t.setBackgroundColor(Color.rgb(23,32,51));r.addView(t);'
if ext: java+='ImageView logo=new ImageView(this); logo.setImageResource(com.appcreator.R.drawable.app_logo); logo.setAdjustViewBounds(true); logo.setPadding(12,12,12,12); r.addView(logo,new LinearLayout.LayoutParams(-1,100));'
java+='WebView w=new WebView(this);w.getSettings().setJavaScriptEnabled(true);w.getSettings().setDomStorageEnabled(true);w.setWebViewClient(new WebViewClient());w.loadUrl("'+u+'");r.addView(w,new LinearLayout.LayoutParams(-1,0,1));setContentView(r);}}'
(r/'app/src/main/java/com/appcreator/MainActivity.java').write_text(java)
PY
STEP='gradle-build'; (cd "$root" && timeout 300s gradle --build-cache --no-daemon assembleRelease)
APK=$(find "$root/app/build/outputs/apk/release" -name '*.apk'|head -1); [ -s "$APK" ] || { echo 'Release APK was not produced'; exit 1; }
STEP='sign'; BT="${ANDROID_BUILD_TOOLS:-$ANDROID_HOME/build-tools/$(ls "$ANDROID_HOME/build-tools"|sort -V|tail -1)}"; KEYSTORE_PASSWORD="${APK_KEYSTORE_PASSWORD:-AppCreatorRelease2026!}"; KEY_PASSWORD="${APK_KEY_PASSWORD:-$KEYSTORE_PASSWORD}"; KEY_ALIAS="${APK_KEY_ALIAS:-appcreator}"; export KEYSTORE_PASSWORD KEY_PASSWORD
if [ -n "${APK_KEYSTORE_B64:-}" ]; then printf '%s' "$APK_KEYSTORE_B64" | base64 -d > release-key.jks; else keytool -genkeypair -keystore release-key.jks -storepass "$KEYSTORE_PASSWORD" -keypass "$KEY_PASSWORD" -alias "$KEY_ALIAS" -keyalg RSA -keysize 2048 -validity 10000 -dname 'CN=App Creator,O=App Creator,C=IN' -noprompt >/dev/null; fi
"$BT/zipalign" -f -p 4 "$APK" app-release-aligned.apk; "$BT/apksigner" sign --ks release-key.jks --ks-pass env:KEYSTORE_PASSWORD --key-pass env:KEY_PASSWORD --ks-key-alias "$KEY_ALIAS" --out app-release.apk app-release-aligned.apk
STEP='validate'; "$BT/zipalign" -c -v 4 app-release.apk; "$BT/apksigner" verify --verbose app-release.apk; "$BT/aapt2" dump badging app-release.apk | tee badging.txt; grep -Fq "application-label:'$APP_NAME'" badging.txt
STEP='publish-release'; TAG="build-$BUILD_ID-$(date +%s)"; URL="https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/app-release.apk"; export GH_TOKEN="$GITHUB_TOKEN"; timeout 120s gh release create "$TAG" app-release.apk --repo "$GITHUB_REPOSITORY" --title "$APP_NAME APK" --notes 'Verified signed APK' --latest=false
STEP='finish'; worker "{\"action\":\"finish\",\"build_id\":\"$BUILD_ID\",\"project_id\":\"$PROJECT_ID\",\"apk_url\":\"$URL\",\"build_log\":\"APK built, signed and verified successfully\"}" >/dev/null
FINAL_SENT=1; echo "APK_RELEASE_URL=$URL"