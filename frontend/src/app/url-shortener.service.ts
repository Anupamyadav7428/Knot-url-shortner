import { Injectable } from '@angular/core';
import { HttpClient, HttpHeaders } from '@angular/common/http';
import { Observable } from 'rxjs';
import { environment } from '../environments/environment';

export interface LinkResponse {
  shortUrl: string;
  code: string;
  originalUrl: string;
  clicks: number;
  createdAt: string | null;
}

export interface DailyClicks {
  date: string;
  clicks: number;
}

const CLIENT_ID_KEY = 'knot-client-id';
const CLIENT_ID_HEADER = 'X-Client-Id';

@Injectable({ providedIn: 'root' })
export class UrlShortenerService {
  private readonly baseUrl = environment.apiBaseUrl;
  private readonly clientId = this.loadOrCreateClientId();

  constructor(private http: HttpClient) {}

  shorten(originalUrl: string, alias: string): Observable<LinkResponse> {
    return this.http.post<LinkResponse>(
      `${this.baseUrl}/shorten`,
      { originalUrl, alias },
      { headers: this.headers() }
    );
  }

  listLinks(): Observable<LinkResponse[]> {
    return this.http.get<LinkResponse[]>(`${this.baseUrl}/api/links`, { headers: this.headers() });
  }

  deleteLink(code: string): Observable<void> {
    return this.http.delete<void>(`${this.baseUrl}/api/links/${code}`, { headers: this.headers() });
  }

  dailyClicks(): Observable<DailyClicks[]> {
    return this.http.get<DailyClicks[]>(`${this.baseUrl}/api/analytics/daily`, { headers: this.headers() });
  }

  private headers(): HttpHeaders {
    return new HttpHeaders({ [CLIENT_ID_HEADER]: this.clientId });
  }

  // Identifies this browser to the backend so /api/links and the analytics
  // chart only ever show links this browser created, not everyone's. There's
  // no login system, so a random id is generated once and kept in
  // localStorage rather than tied to a real account.
  private loadOrCreateClientId(): string {
    try {
      const existing = localStorage.getItem(CLIENT_ID_KEY);
      if (existing) {
        return existing;
      }
      const created = crypto.randomUUID();
      localStorage.setItem(CLIENT_ID_KEY, created);
      return created;
    } catch {
      return crypto.randomUUID();
    }
  }
}
