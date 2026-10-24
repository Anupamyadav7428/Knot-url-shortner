export const environment = {
  production: true,
  apiBaseUrl: (window as Window & { __KNOT_CONFIG__?: { apiBaseUrl?: string } })
    .__KNOT_CONFIG__?.apiBaseUrl ?? 'https://knot-url-shortner.onrender.com'
};