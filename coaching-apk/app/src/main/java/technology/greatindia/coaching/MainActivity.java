package technology.greatindia.techearadmin;

import android.app.Activity;
import android.os.Bundle;
import android.graphics.Color;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

public class MainActivity extends Activity {
    private static final String START_URL =
        "https://coaching.greatindia.technology/?utm_source=chatgpt.com/c/kartar-classes";

    @Override
    public void onCreate(Bundle b) {
        super.onCreate(b);
        WebView w = new WebView(this);
        w.setBackgroundColor(Color.WHITE);
        WebSettings s = w.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(true);
        w.setWebViewClient(new WebViewClient());
        w.setWebChromeClient(new WebChromeClient());
        w.loadUrl(START_URL);
        setContentView(w);
    }

    @Override
    public void onBackPressed() {
        WebView w = (WebView) findViewById(android.R.id.content);
        if (w != null && w.canGoBack()) w.goBack();
        else super.onBackPressed();
    }
}