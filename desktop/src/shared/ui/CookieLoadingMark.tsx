import type { CSSProperties } from "react";
import { useId } from "react";

import { cn } from "@/shared/lib/cn";

type Circle = readonly [cx: number, cy: number, r: number];
type Crumb = readonly [
  x: number,
  y: number,
  side: number,
  delaySeconds: number,
];

const CHIPS: readonly Circle[] = [
  [23, 23, 3.9],
  [38, 19.5, 3.3],
  [42, 35, 4.1],
  [26.5, 40.5, 3.6],
  [33, 30, 2.6],
  [18, 33, 2.4],
];

// Each bite is three overlapping circles cut from the cookie's edge.
const BITES: readonly (readonly Circle[])[] = [
  [
    [49.4, 11.3, 9.5],
    [40.7, 8, 6.5],
    [54.1, 19.3, 6.5],
  ],
  [
    [58.6, 36.7, 9.5],
    [57.1, 27.6, 6.5],
    [54.1, 44.8, 6.5],
  ],
  [
    [41.2, 57.4, 9.5],
    [48.4, 51.5, 6.5],
    [32, 57.5, 6.5],
  ],
];

const BITE_CRUMBS: readonly (readonly Crumb[])[] = [
  [
    [40.2, 14.6, 2.6, 0],
    [45, 14.9, 2, 0.04],
    [48.9, 14.8, 2.3, 0.08],
  ],
  [
    [47.4, 34.3, 2.6, 0],
    [52.2, 34.6, 2, 0.04],
    [56.1, 34.5, 2.3, 0.08],
  ],
  [
    [33.9, 50.4, 2.6, 0],
    [38.7, 50.7, 2, 0.04],
    [42.6, 50.6, 2.3, 0.08],
  ],
];

const PILE_CRUMBS: readonly Crumb[] = [
  [20, 26, 3, 0],
  [26, 30, 2.4, 0.03],
  [31, 34, 3.2, 0.06],
  [37, 26, 2.6, 0.09],
  [43, 30, 3, 0],
  [23, 34, 2.2, 0.03],
  [34, 26, 2.2, 0.06],
  [40, 30, 2.4, 0.09],
];

const BITE_FALL = 16;
const PILE_FALL = 22;

function CookieFrame({ bites, maskId }: { bites: number; maskId: string }) {
  const id = `${maskId}-${bites}`;
  return (
    <svg
      aria-hidden="true"
      className={`cookie-loader__frame cookie-loader__frame--${bites}`}
      viewBox="0 0 64 64"
    >
      {bites > 0 ? (
        <mask
          height="64"
          id={id}
          maskUnits="userSpaceOnUse"
          width="64"
          x="0"
          y="0"
        >
          <rect fill="#fff" height="64" width="64" />
          {BITES.slice(0, bites)
            .flat()
            .map(([cx, cy, r]) => (
              <circle cx={cx} cy={cy} fill="#000" key={`${cx}-${cy}`} r={r} />
            ))}
        </mask>
      ) : null}
      <g mask={bites > 0 ? `url(#${id})` : undefined}>
        <circle
          cx="32"
          cy="32"
          fill="#D99A4E"
          r="24"
          stroke="#B87634"
          strokeWidth="2.5"
        />
        {CHIPS.map(([cx, cy, r]) => (
          <circle cx={cx} cy={cy} fill="#4A2C17" key={`${cx}-${cy}`} r={r} />
        ))}
      </g>
    </svg>
  );
}

function crumbStyle(
  [x, y, side, delaySeconds]: Crumb,
  fall: number,
): CSSProperties {
  return {
    animationDelay: `${delaySeconds}s`,
    height: `${(side / 64) * 100}%`,
    left: `${(x / 64) * 100}%`,
    top: `${(y / 64) * 100}%`,
    width: `${(side / 64) * 100}%`,
    // Translate percentages are of the crumb's own size, so the fall in
    // design units is converted per crumb.
    ["--cookie-crumb-fall" as string]: `${(fall / side) * 100}%`,
  };
}

/**
 * Snack's loading mascot: a cookie eaten bite by bite on a 2 second loop,
 * crumbs falling from each bite. Colors are fixed brand colors that read on
 * light and dark themes. Reduced motion shows the whole cookie, still.
 *
 * Every animated element is HTML-level (four stacked SVG frames with 0-3
 * bites, plus crumb spans) and only opacity and transform animate, so the
 * loop runs on the compositor and keeps moving while boot work holds the main
 * thread (WebKit paints animated SVG children on the main thread). Size it
 * with a width class; the box is square.
 */
export function CookieLoadingMark({
  className,
  label,
}: {
  className?: string;
  /** Accessible name; omit when an ancestor already announces the state. */
  label?: string;
}) {
  const maskId = `cookie-bites-${useId().replace(/[^a-zA-Z0-9_-]/g, "")}`;
  const a11y = label
    ? ({ "aria-label": label, role: "img" } as const)
    : ({ "aria-hidden": true } as const);

  return (
    <div
      className={cn("cookie-loader", className)}
      data-testid="cookie-loading-mark"
      {...a11y}
    >
      <div className="cookie-loader__cookie">
        {[0, 1, 2, 3].map((bites) => (
          <CookieFrame bites={bites} key={bites} maskId={maskId} />
        ))}
      </div>
      {BITE_CRUMBS.map((crumbs, bite) =>
        crumbs.map((crumb) => (
          <span
            className={`cookie-loader__crumb cookie-loader__crumb--${bite + 1}`}
            key={`${crumb[0]}-${crumb[1]}`}
            style={crumbStyle(crumb, BITE_FALL)}
          />
        )),
      )}
      {PILE_CRUMBS.map((crumb) => (
        <span
          className="cookie-loader__crumb cookie-loader__crumb--pile"
          key={`${crumb[0]}-${crumb[1]}`}
          style={crumbStyle(crumb, PILE_FALL)}
        />
      ))}
    </div>
  );
}
