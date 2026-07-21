"""
Connect ZoomInfo — interactive OAuth (Authorization Code + PKCE) sign-in page.

A Snowflake stored procedure can't run a browser login, so the interactive step
lives here. But the actual network calls to ZoomInfo (and reading the OAuth
client secret) happen in stored procedures that hold the external-access +
secret references — this Streamlit object needs no external access itself. It
only orchestrates:

  1. Call core.begin_connect() -> {authorize_url, verifier, state}. Show the link.
  2. The user signs in at ZoomInfo and is redirected to the registered
     redirect_uri, which shows an authorization ?code=...
  3. The user pastes that code here; we call core.connect_with_code(code,
     verifier), which exchanges it for tokens and stores them for the calling
     Snowflake user in app_state.oauth_tokens.

Tokens are keyed by CURRENT_USER, so each user connects their own ZoomInfo
account.
"""

import json

import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Connect ZoomInfo", page_icon="🔗")

session = get_active_session()
TOKENS_TABLE = "app_state.oauth_tokens"


def current_user():
    return session.sql("SELECT CURRENT_USER() AS u").collect()[0]["U"]


def load_status():
    rows = session.sql(
        f"SELECT updated_at FROM {TOKENS_TABLE} WHERE sf_user = CURRENT_USER()"
    ).collect()
    return rows[0] if rows else None


def call_begin_connect():
    """Call the OAuth-start procedure; returns the parsed VARIANT dict."""
    row = session.sql("CALL core.begin_connect()").collect()[0]
    return json.loads(row[0])


st.title("🔗 Connect ZoomInfo")
st.caption(
    "Sign in to your ZoomInfo account to authorize this app to call the GTM API "
    "on your behalf. Your connection is private to your Snowflake user."
)

# Show existing connection status.
status = load_status()
if status is not None:
    st.success(f"Connected as Snowflake user **{current_user()}**.")
    st.write(f"Token last updated: {status['UPDATED_AT']}")
else:
    st.info("Not connected yet. Follow the two steps below.")

st.divider()

# --- Step 1: authorize link -------------------------------------------------
# begin_connect() returns a fresh verifier + state each time it's built. Persist
# them across reruns so the code exchange uses the SAME verifier that produced
# the challenge in the authorize URL.
if "oauth_start" not in st.session_state:
    try:
        st.session_state["oauth_start"] = call_begin_connect()
    except Exception as exc:  # noqa: BLE001 — surface config/binding problems plainly
        st.error(
            "This app isn't fully configured yet. An account admin needs to bind the "
            "ZoomInfo OAuth client secret and external access integration, which also "
            f"creates the sign-in procedures.\n\n{exc}"
        )
        st.stop()

authorize_url = st.session_state["oauth_start"]["authorize_url"]

st.subheader("Step 1 — Sign in to ZoomInfo")
st.markdown(f"[Open the ZoomInfo sign-in page ↗]({authorize_url})")
st.caption(
    "A new tab opens. After you approve, ZoomInfo redirects to the app's "
    "registered redirect URL and shows an authorization **code**. Copy it."
)

# --- Step 2: paste code + exchange -----------------------------------------
st.subheader("Step 2 — Paste the authorization code")
with st.form("exchange"):
    code = st.text_input("Authorization code", type="password", placeholder="Paste the code from ZoomInfo")
    submitted = st.form_submit_button("Connect")

if submitted:
    if not code.strip():
        st.warning("Paste the authorization code first.")
    else:
        try:
            verifier = st.session_state["oauth_start"]["verifier"]
            row = session.sql(
                "CALL core.connect_with_code(?, ?)", params=[code.strip(), verifier]
            ).collect()[0]
            result = json.loads(row[0])
            # Force a fresh start for any future re-connect.
            del st.session_state["oauth_start"]
            st.success(f"Connected! Granted scopes: {result.get('scope') or '(default scopes)'}")
            st.rerun()
        except Exception as exc:  # noqa: BLE001 — show ZoomInfo's error to the user
            st.error(f"Could not connect: {exc}")
