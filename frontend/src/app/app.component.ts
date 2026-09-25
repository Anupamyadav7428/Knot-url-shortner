import { Component, OnInit } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { DecimalPipe } from '@angular/common';
import { HttpErrorResponse } from '@angular/common/http';
import { DailyClicks, LinkResponse, UrlShortenerService } from './url-shortener.service';

const THEME_KEY = 'knot-theme';
const CHART_WIDTH = 600;
const CHART_HEIGHT = 140;

interface ChartPoint {
  x: number;
  y: number;
  label: string;
  value: number;
}

@Component({
  selector: 'app-root',
  imports: [FormsModule, DecimalPipe],
  templateUrl: './app.component.html',
  styleUrl: './app.component.css'
})
export class AppComponent implements OnInit {
  originalUrl = '';
  alias = '';
  errorMessage: string | null = null;
  loading = false;

  links: LinkResponse[] = [];
  linksLoaded = false;
  copiedCode: string | null = null;
  justCreatedCode: string | null = null;

  dailyClicksData: DailyClicks[] = [];

  theme: 'light' | 'dark' = 'light';
  readonly currentYear = new Date().getFullYear();

  constructor(private urlShortenerService: UrlShortenerService) {
    this.theme = this.loadTheme();
  }

  ngOnInit(): void {
    this.refreshLinks();
    this.refreshAnalytics();
  }

  shorten(): void {
    const url = this.originalUrl.trim();
    if (!url) {
      return;
    }

    this.loading = true;
    this.errorMessage = null;

    this.urlShortenerService.shorten(url, this.alias.trim()).subscribe({
      next: (result) => {
        this.loading = false;
        this.originalUrl = '';
        this.alias = '';
        this.justCreatedCode = result.code;
        this.links = [result, ...this.links.filter((l) => l.code !== result.code)].slice(0, 10);
        setTimeout(() => {
          if (this.justCreatedCode === result.code) {
            this.justCreatedCode = null;
          }
        }, 2000);
      },
      error: (err: HttpErrorResponse) => {
        this.loading = false;
        this.errorMessage = err.error?.message ?? 'Could not shorten that URL. Please check it and try again.';
      }
    });
  }

  copyLink(link: LinkResponse): void {
    navigator.clipboard.writeText(link.shortUrl).then(() => {
      this.copiedCode = link.code;
      setTimeout(() => {
        if (this.copiedCode === link.code) {
          this.copiedCode = null;
        }
      }, 2000);
    });
  }

  removeLink(link: LinkResponse): void {
    this.urlShortenerService.deleteLink(link.code).subscribe(() => {
      this.links = this.links.filter((l) => l.code !== link.code);
    });
  }

  toggleTheme(): void {
    this.theme = this.theme === 'dark' ? 'light' : 'dark';
    localStorage.setItem(THEME_KEY, this.theme);
  }

  formatDate(iso: string | null): string {
    if (!iso) {
      return '—';
    }
    return new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  }

  trackByCode(_index: number, link: LinkResponse): string {
    return link.code;
  }

  get totalClicksLast7Days(): number {
    return this.dailyClicksData.reduce((sum, d) => sum + d.clicks, 0);
  }

  get chartPoints(): ChartPoint[] {
    const values = this.dailyClicksData.map((d) => d.clicks);
    const max = Math.max(...values, 1);
    const stepX = CHART_WIDTH / Math.max(values.length - 1, 1);

    return this.dailyClicksData.map((d, i) => ({
      x: i * stepX,
      y: CHART_HEIGHT - (d.clicks / max) * (CHART_HEIGHT - 16) - 8,
      label: this.dayLabel(d.date, i),
      value: d.clicks
    }));
  }

  get chartLinePath(): string {
    const pts = this.chartPoints;
    if (pts.length === 0) {
      return '';
    }
    return 'M ' + pts.map((p) => `${p.x},${p.y}`).join(' L ');
  }

  get chartAreaPath(): string {
    const pts = this.chartPoints;
    if (pts.length === 0) {
      return '';
    }
    const first = pts[0];
    const last = pts[pts.length - 1];
    return `M ${first.x},${CHART_HEIGHT} L ` + pts.map((p) => `${p.x},${p.y}`).join(' L ') + ` L ${last.x},${CHART_HEIGHT} Z`;
  }

  private dayLabel(dateStr: string, index: number): string {
    if (index === this.dailyClicksData.length - 1) {
      return 'Today';
    }
    return new Date(`${dateStr}T00:00:00`).toLocaleDateString(undefined, { weekday: 'short' });
  }

  private refreshLinks(): void {
    this.urlShortenerService.listLinks().subscribe({
      next: (links) => {
        this.links = links;
        this.linksLoaded = true;
      },
      error: () => {
        this.linksLoaded = true;
      }
    });
  }

  private refreshAnalytics(): void {
    this.urlShortenerService.dailyClicks().subscribe({
      next: (data) => (this.dailyClicksData = data)
    });
  }

  private loadTheme(): 'light' | 'dark' {
    try {
      const saved = localStorage.getItem(THEME_KEY);
      if (saved === 'light' || saved === 'dark') {
        return saved;
      }
    } catch {
      // localStorage unavailable - fall through to system preference.
    }
    return window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }
}
