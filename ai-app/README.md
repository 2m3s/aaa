# Pocket AI: a free AI app for iPhone

A small AI assistant that you add to your iPhone home screen. It opens full-screen like a normal app, but it's just a web page, so you don't need a Mac, Xcode or an Apple developer account. It costs nothing to run: it uses the free tier of an AI provider, with a key you get yourself.

- **Modes:** Chat, Summarize, Rewrite, Fix grammar, Translate, Explain simply, Code
- **Providers:** Google Gemini, Groq or OpenRouter. All three have free keys.
- Replies stream in as they're written. There's a Copy button under each reply and a Stop button while it's writing.
- Your chat and key are saved on the phone and survive closing the app. **+** starts a new chat.
- Follows light and dark mode.

## 1. Put it online (free, once)

The app has to be served from a web address so Safari can install it. The easiest way is GitHub Pages from this repo:

1. On GitHub, open the repo → **Settings** → **Pages**.
2. Under **Build and deployment**, pick **Deploy from a branch**, branch **`main`**, folder **`/ (root)`**, and click **Save**.
3. After a minute the app is live at **`https://2m3s.github.io/aaa/ai-app/`**.

GitHub Pages is free for public repos. Any other static host works too: drag the `ai-app` folder onto [Netlify Drop](https://app.netlify.com/drop) or Cloudflare Pages.

## 2. Install it on the iPhone

1. Open the address above in **Safari**.
2. Tap **Share** (the square with the arrow) → **Add to Home Screen** → **Add**.
3. Open **Pocket AI** from the home screen.

## 3. Get a free API key

Tap ⚙︎ in the app, pick a provider and paste its key:

| Provider | Get a key | Notes |
|---|---|---|
| **Google Gemini** (default) | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) | Smartest of the three on the free tier; no card needed. |
| **Groq** | [console.groq.com/keys](https://console.groq.com/keys) | Very fast replies (Llama models). |
| **OpenRouter** | [openrouter.ai/keys](https://openrouter.ai/keys) | Many models; the free ones end in `:free`. |

Free tiers have rate limits (a set number of requests per minute and per day). If you see a "rate limit" message, wait a minute, or switch provider in Settings.

Providers rename models now and then. If you get a "model not found" error, type a current model name into **Model** in Settings. You'll find the names on the provider's site. Clearing the box puts the default back.

## Privacy and your key

The key is stored only in Safari's storage on your phone, and messages go straight from your phone to the provider you picked. Nothing passes through this repo or any server of ours. Don't type your key into the code or commit it: anyone could copy it from a public page.

## Files

| File | What it is |
|---|---|
| `index.html` | The page |
| `style.css` | Look and feel, light and dark |
| `app.js` | Modes, providers, streaming, settings, saved chat |
| `sw.js` | Service worker that caches the app so it opens instantly |
| `manifest.webmanifest`, `icon*` | Home-screen name and icon |

To try it on a computer, run `python3 -m http.server` inside `ai-app/` and open `http://localhost:8000`.

To add a mode, add an entry to `MODES` in `app.js` with a label and a system prompt.
