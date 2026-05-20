// ═══════════════════════════════════════════════════════════════════════════
// auth.js
// Handles: session validation, role-based page guards, dynamic navbar,
//          logout, and user display name.
//
// Usage: Every protected page loads this as a module script:
//   <script type="module">
//     import { initAuth } from '../scripts/auth.js';
//     initAuth('page-key');   ← pass the page key defined in PAGE_ACCESS below
//   </script>
// ═══════════════════════════════════════════════════════════════════════════

import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm';
const supabase = createClient(
    'https://fyhgvxfrwbwuqxllodip.supabase.co',
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ5aGd2eGZyd2J3dXF4bGxvZGlwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxMzk5ODIsImV4cCI6MjA5NDcxNTk4Mn0.665OZwCsBvnHCVZ-ApiF2xM1CBgTIYZe2EEbuW7IW3U'
);

// ── Role → allowed pages map ─────────────────────────────────────────────
// Keys match the `pageKey` argument passed to initAuth()
const PAGE_ACCESS = {
    'index':           ['head_coach', 'sc_staff'],
    'dashboard':       ['head_coach', 'sc_staff', 'athletic_trainer'],
    'load_management': ['sc_staff'],
    'cmj':             ['sc_staff'],
    'nordbord':        ['sc_staff', 'athletic_trainer'],
    'injury_risk':     ['sc_staff', 'athletic_trainer'],
    'roster':          ['sc_staff', 'athletic_trainer'],
};

// ── Nav links per role ────────────────────────────────────────────────────
const NAV_LINKS = {
    head_coach:       [],
    sc_staff:         [],
    athletic_trainer: [],
};

// ── Page titles for nav active-state detection ────────────────────────────
// Matches key → partial filename so it works from Supabase Storage URLs too
function getCurrentPageKey() {
    const path = window.location.pathname;
    for (const key of Object.keys(PAGE_ACCESS)) {
        if (path.includes(key === 'index' ? 'index' : key)) return key;
    }
    return 'index';
}

// ── Main entry point ──────────────────────────────────────────────────────
export async function initAuth(pageKey, options = {}) {
    // 1. Check for a valid Supabase session
    const { data: { session }, error: sessionError } = await supabase.auth.getSession();

    if (sessionError || !session) {
        redirectToLogin();
        return null;
    }

    // 2. Fetch the user's profile (role + name)
    const { data: profile, error: profileError } = await supabase
        .from('profiles')
        .select('full_name, role')
        .eq('id', session.user.id)
        .single();

    if (profileError || !profile) {
        console.error('[auth] Could not load profile:', profileError?.message);
        redirectToLogin();
        return null;
    }

    const { role, full_name } = profile;

    // 3. Role-based page guard
    const allowedRoles = PAGE_ACCESS[pageKey] ?? [];
    if (!allowedRoles.includes(role)) {
        // Role not permitted for this page → send to command center
        window.location.href = './index.html';
        return null;
    }

    // 4. Inject the navbar (skip if page has its own nav)
    if (!options.skipNavbar) {
        renderNavbar(role, full_name, pageKey || getCurrentPageKey());
    }

    // 5. Listen for auth state changes (e.g. token expiry)
    supabase.auth.onAuthStateChange((event) => {
        if (event === 'SIGNED_OUT') redirectToLogin();
    });

    // Return profile so pages can use role/name if needed
    return { session, role, full_name };
}

// ── Render navbar ─────────────────────────────────────────────────────────
function renderNavbar(role, fullName, activeKey) {
    const links = NAV_LINKS[role] ?? [];

    const navHTML = `
    <nav id="uf-navbar">
        <div class="nav-inner">
            <a href="./index.html" class="nav-logo">UF S&amp;C</a>

            <div class="nav-links">
                ${links.map(link => `
                    <a href="${link.href}"
                       class="nav-link ${link.key === activeKey ? 'nav-link--active' : ''}">
                        ${link.label}
                    </a>
                `).join('')}
            </div>

            <div class="nav-user">
                <span class="nav-username">${escapeHTML(fullName)}</span>
                <button class="btn-logout" id="logout-btn">Logout</button>
            </div>
        </div>
    </nav>`;

    // Insert at top of body
    document.body.insertAdjacentHTML('afterbegin', navHTML);

    // Wire logout
    document.getElementById('logout-btn').addEventListener('click', handleLogout);

    // Inject navbar styles (scoped — won't conflict with page styles)
    injectNavStyles();
}

// ── Logout ────────────────────────────────────────────────────────────────
async function handleLogout() {
    const btn = document.getElementById('logout-btn');
    if (btn) { btn.textContent = 'Signing out…'; btn.disabled = true; }

    const { error } = await supabase.auth.signOut();
    if (error) {
        console.error('[auth] Logout error:', error.message);
    }
    redirectToLogin();
}

// ── Helpers ───────────────────────────────────────────────────────────────
function redirectToLogin() {
    window.location.href = './login.html';
}

function escapeHTML(str) {
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

// ── Navbar CSS (injected once) ────────────────────────────────────────────
function injectNavStyles() {
    if (document.getElementById('uf-navbar-styles')) return;

    const style = document.createElement('style');
    style.id = 'uf-navbar-styles';
    style.textContent = `
        /* ── UF S&C Navbar ─────────────────────────────── */
        #uf-navbar {
            position: sticky;
            top: 0;
            z-index: 1000;
            background-color: #003087;   /* UF Blue */
            box-shadow: 0 2px 4px rgba(0,0,0,0.25);
        }

        .nav-inner {
            display: flex;
            align-items: center;
            justify-content: space-between;
            max-width: 1400px;
            margin: 0 auto;
            padding: 0 1.5rem;
            height: 56px;
        }

        .nav-logo {
            font-family: 'Inter', sans-serif;
            font-size: 1.2rem;
            font-weight: 700;
            color: #FA4616;   /* UF Orange */
            text-decoration: none;
            letter-spacing: 0.02em;
            flex-shrink: 0;
        }

        .nav-links {
            display: flex;
            gap: 0.25rem;
            flex: 1;
            justify-content: center;
        }

        .nav-link {
            font-family: 'Inter', sans-serif;
            font-size: 0.875rem;
            font-weight: 500;
            color: #ffffff;
            text-decoration: none;
            padding: 0.375rem 0.875rem;
            border-radius: 6px;
            transition: background 0.15s ease;
        }

        .nav-link:hover {
            background-color: rgba(255,255,255,0.12);
        }

        .nav-link--active {
            background-color: #FA4616;
            color: #ffffff;
        }

        .nav-link--active:hover {
            background-color: #e03d10;
        }

        .nav-user {
            display: flex;
            align-items: center;
            gap: 0.75rem;
            flex-shrink: 0;
        }

        .nav-username {
            font-family: 'Inter', sans-serif;
            font-size: 0.8rem;
            color: rgba(255,255,255,0.75);
            white-space: nowrap;
        }

        .btn-logout {
            font-family: 'Inter', sans-serif;
            font-size: 0.8rem;
            font-weight: 500;
            color: #ffffff;
            background: transparent;
            border: 1px solid rgba(255,255,255,0.4);
            border-radius: 6px;
            padding: 0.3rem 0.75rem;
            cursor: pointer;
            transition: background 0.15s ease, border-color 0.15s ease;
            white-space: nowrap;
        }

        .btn-logout:hover {
            background: rgba(255,255,255,0.12);
            border-color: rgba(255,255,255,0.7);
        }

        .btn-logout:disabled {
            opacity: 0.5;
            cursor: not-allowed;
        }

        /* ── Responsive: collapse nav links on mobile ── */
        @media (max-width: 768px) {
            .nav-links {
                display: none;   /* replaced by hamburger in future iteration */
            }
            .nav-username {
                display: none;
            }
        }
    `;

    document.head.appendChild(style);
}

// ── Utility: export a ready-to-use spinner helper for page scripts ────────
export function showSpinner(containerId) {
    const el = document.getElementById(containerId);
    if (!el) return;
    el.innerHTML = `
        <div class="uf-spinner-wrap">
            <div class="uf-spinner"></div>
        </div>`;
    injectSpinnerStyles();
}

export function hideSpinner(containerId) {
    const el = document.getElementById(containerId);
    if (el) el.querySelector('.uf-spinner-wrap')?.remove();
}

export function showError(containerId, message) {
    const el = document.getElementById(containerId);
    if (!el) return;
    el.innerHTML = `
        <div class="uf-error-box">
            <span class="uf-error-icon">⚠️</span>
            <span>${escapeHTML(message)}</span>
        </div>`;
    injectSpinnerStyles();
}

function injectSpinnerStyles() {
    if (document.getElementById('uf-spinner-styles')) return;
    const style = document.createElement('style');
    style.id = 'uf-spinner-styles';
    style.textContent = `
        .uf-spinner-wrap {
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 120px;
        }
        .uf-spinner {
            width: 40px;
            height: 40px;
            border: 4px solid #e5e7eb;
            border-top-color: #FA4616;
            border-radius: 50%;
            animation: uf-spin 0.75s linear infinite;
        }
        @keyframes uf-spin {
            to { transform: rotate(360deg); }
        }
        .uf-error-box {
            display: flex;
            align-items: center;
            gap: 0.75rem;
            background: #fef2f2;
            border: 1px solid #fecaca;
            border-radius: 8px;
            padding: 1rem 1.25rem;
            color: #991b1b;
            font-family: 'Inter', sans-serif;
            font-size: 0.9rem;
            margin: 1rem 0;
        }
        .uf-error-icon { font-size: 1.1rem; }
    `;
    document.head.appendChild(style);
}
