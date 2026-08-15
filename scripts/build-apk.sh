#!/usr/bin/env bash
set -euo pipefail
: "${SUPABASE_URL:?SUPABASE_URL secret is required}"
: "${SUPABASE_SERVICE_ROLE_KEY:?SUPABASE_SERVICE_ROLE_KEY secret is required}"
api="$SUPABASE_URL/rest/v1"
headers=(-H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" -H 'Content-Type: application/json' -H 'Prefer: return=representation')
row='[]'
BUILD_ID=''
if [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ]; then
  BUILD_ID=$(python3 - "$GITHUB_EVENT_PATH" <<'PY'
import json,sys
try:
 d=json.load(open(sys.argv[1])); print((d.get('client_payload') or {}).get('build_id') or '')
except Exception: print('')
PY
  )
fi
if [ -n "$BUILD_ID" ]; then
  row=$(curl -fsS "${headers[@]}" "$api/app_creator_builds?select=id,project_id,status,created_at,app_creator_projects(id,slug,name,target_url,logo_data)&id=eq.$BUILD_ID&limit=1")
else
  for i in $(seq 1 24); do
    row=$(curl -fsS "${headers[@]}" "$api/app_creator_builds?select=id,project_id,status,created_at,app_creator_projects(id,slug,name,target_url,logo_data)&status=eq.queued&order=created_at.asc&limit=1")
    if [ "$row" != "[]" ]; then break; fi
    sleep 5
  done
fi
[ "$row" != "[]" ] || { echo 'Requested build not found'; exit 1; }
BUILD_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])' <<<"$row")
PROJECT_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["project_id"])' <<<"$row")
APP_NAME=$(python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["app_creator_projects"]["name"])' <<<"$row")
SLUG=$(python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["app_creator_projects"]["slug"])' <<<"$row")
TARGET_URL=$(python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["app_creator_projects"]["target_url"])' <<<"$row")
LOGO_DATA=$(python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["app_creator_projects"].get("logo_data") or "")' <<<"$row")
curl -fsS -X PATCH "${headers[@]}" --data '{"status":"building"}' "$api/app_creator_builds?id=eq.$BUILD_ID&status=eq.queued" >/dev/null
export BUILD_ID PROJECT_ID APP_NAME SLUG TARGET_URL LOGO_DATA
printf 'build_id=%s\nproject_id=%s\napp_name=%s\nslug=%s\ntarget_url=%s\n' "$BUILD_ID" "$PROJECT_ID" "$APP_NAME" "$SLUG" "$TARGET_URL" >> "$GITHUB_OUTPUT"
root=buildapp
mkdir -p "$root/app/src/main/java/com/appcreator" "$root/app/src/main/res/values" "$root/app/src/main/res/drawable"
slug_clean=$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-24); slug_clean=${slug_clean:-app}
cat > "$root/settings.gradle" <<'EOF'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS); repositories { google(); mavenCentral() } }
rootProject.name='AppCreatorBuild'
include ':app'
EOF
cat > "$root/build.gradle" <<'EOF'
plugins { id 'com.android.application' version '8.6.1' apply false }
EOF
cat > "$root/app/build.gradle" <<EOF
plugins { id 'com.android.application' }
android { namespace 'com.appcreator'; compileSdk 35; defaultConfig { applicationId 'com.appcreator.$slug_clean'; minSdk 23; targetSdk 35; versionCode 1; versionName '1.0' } }
EOF
python3 - <<'PY'
import os,base64,pathlib,html
r=pathlib.Path('buildapp'); name=html.escape(os.environ['APP_NAME'],quote=True); target=os.environ['TARGET_URL'].replace('\\','\\\\').replace('"','\\"')
(r/'app/src/main/res/values/strings.xml').write_text(f'<resources><string name="app_name">{name}</string></resources>')
(r/'app/src/main/res/values/styles.xml').write_text('<resources><style name="AppTheme" parent="android:style/Theme.Material.Light.NoActionBar"/></resources>')
logo=os.environ.get('LOGO_DATA','')
if logo.startswith('data:image/') and ';base64,' in logo:
 m,p=logo.split(';base64,',1); ext='png' if 'png' in m else ('webp' if 'webp' in m else 'jpg'); (r/f'app/src/main/res/drawable/app_logo.{ext}').write_bytes(base64.b64decode(p)); icon='@drawable/app_logo'
else:
 (r/'app/src/main/res/drawable/app_logo.xml').write_text('<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="48dp" android:height="48dp" android:viewportWidth="48" android:viewportHeight="48"><path android:fillColor="#087F5B" android:pathData="M24,4A20,20 0,1 0,24 44A20,20 0,1 0,24 4M24,10A14,14 0,1 1,24 38A14,14 0,1 1,24 10"/></vector>'); icon='@drawable/app_logo'
(r/'app/src/main/AndroidManifest.xml').write_text(f'<manifest xmlns:android="http://schemas.android.com/apk/res/android"><uses-permission android:name="android.permission.INTERNET"/><application android:theme="@style/AppTheme" android:label="@string/app_name" android:icon="{icon}"><activity android:name=".MainActivity" android:exported="true"><intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter></activity></application></manifest>')
java='package com.appcreator; import android.app.*; import android.os.*; import android.graphics.Color; import android.webkit.*; import android.widget.*; public class MainActivity extends Activity { public void onCreate(Bundle b){super.onCreate(b); LinearLayout r=new LinearLayout(this);r.setOrientation(LinearLayout.VERTICAL); TextView t=new TextView(this);t.setText(R.string.app_name);t.setTextColor(Color.WHITE);t.setTextSize(19);t.setPadding(16,8,8,8);t.setBackgroundColor(Color.rgb(23,32,51));r.addView(t);WebView w=new WebView(this);w.getSettings().setJavaScriptEnabled(true);w.getSettings().setDomStorageEnabled(true);w.setWebViewClient(new WebViewClient());w.loadUrl("'+target+'");r.addView(w,new LinearLayout.LayoutParams(-1,0,1));setContentView(r);}}'
(r/'app/src/main/java/com/appcreator/MainActivity.java').write_text(java)
PY
(cd "$root" && gradle --no-daemon clean assembleRelease)
APK=$(find "$root/app/build/outputs/apk/release" -name '*.apk' -type f | head -1)
BT="$ANDROID_HOME/build-tools/$(ls "$ANDROID_HOME/build-tools" | sort -V | tail -1)"
: "${KEYSTORE_PASSWORD:=AppCreatorRelease2026!}"; : "${KEY_PASSWORD:=$KEYSTORE_PASSWORD}"; : "${KEY_ALIAS:=appcreator}"
keytool -genkeypair -keystore release-key.jks -storepass "$KEYSTORE_PASSWORD" -keypass "$KEY_PASSWORD" -alias "$KEY_ALIAS" -keyalg RSA -keysize 2048 -validity 10000 -dname 'CN=App Creator,O=App Creator,C=IN' -noprompt >/dev/null
"$BT/zipalign" -f -p 4 "$APK" app-release-aligned.apk
"$BT/apksigner" sign --ks release-key.jks --ks-pass env:KEYSTORE_PASSWORD --key-pass env:KEY_PASSWORD --ks-key-alias "$KEY_ALIAS" --out app-release.apk app-release-aligned.apk
"$BT/zipalign" -c -v 4 app-release.apk
"$BT/apksigner" verify --verbose app-release.apk
"$BT/aapt2" dump badging app-release.apk | tee badging.txt
grep -Fq "application-label:'$APP_NAME'" badging.txt
TAG="build-$BUILD_ID"; URL="https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/app-release.apk"
gh release create "$TAG" app-release.apk --repo "$GITHUB_REPOSITORY" --title "$APP_NAME APK" --notes 'Verified signed APK' --latest=false
curl -fsS -X PATCH "${headers[@]}" --data "{\"apk_url\":\"$URL\",\"status\":\"ready\"}" "$api/app_creator_projects?id=eq.$PROJECT_ID" >/dev/null
curl -fsS -X PATCH "${headers[@]}" --data "{\"status\":\"ready\",\"apk_path\":\"$URL\"}" "$api/app_creator_builds?id=eq.$BUILD_ID" >/dev/null