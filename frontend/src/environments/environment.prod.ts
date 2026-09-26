export const environment = {
  production: true,
  apiBaseUrl: (window as Window & { __KNOT_CONFIG__?: { apiBaseUrl?: string } })
    .__KNOT_CONFIG__?.apiBaseUrl ?? 'http://localhost:9090'
};
