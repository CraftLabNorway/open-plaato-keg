// PLAATO AIRLOCK REVIVAL - iOS widget for Scriptable
// Community contribution. See README.md in this folder for setup.
//
// Shows the latest temperature and bubbles/min for one airlock,
// plus a combined graph of the last 40 readings.
//
// Temperature: left Y-axis (green)
// Bubbles/min: right Y-axis (orange)
// Timestamp: bottom X-axis (white)
// Axis labels: white
//
// Updated:
// - Separate compact reading boxes
// - Centred live readings
// - Centred legend
// - Improved title left margin

const TOKEN = "PASTE_YOUR_TOKEN_HERE";
// Change this if you run your own open-plaato-keg server
const SERVER = "https://airlock.craftlab.no";
const API = `${SERVER}/api/airlocks/${TOKEN}/log`;

const w = new ListWidget();

const BG = new Color("#173B2B");
const WHITE = new Color("#FFFFFF");
const GREEN = new Color("#43D17A");
const ORANGE = new Color("#FFAA45");
const GRID = new Color("#FFFFFF", 0.20);

w.backgroundColor = BG;
w.setPadding(12, 17, 10, 17);

try {
  // Fetch readings
  const req = new Request(API);
  req.timeoutInterval = 20;

  const response = await req.loadJSON();

  let readings = Array.isArray(response)
    ? response
    : response.readings || response.data || response.logs || [];

  readings = readings
    .map(r => ({
      temperature: Number(r.temperature),
      bubbles: Number(r.bubbles_per_min),
      timestamp: Number(r.timestamp)
    }))
    .filter(r =>
      Number.isFinite(r.temperature) &&
      Number.isFinite(r.bubbles) &&
      Number.isFinite(r.timestamp)
    )
    .sort((a, b) => a.timestamp - b.timestamp)
    .slice(-40);

  if (readings.length < 2) {
    throw new Error("Not enough readings available");
  }

  const latest = readings[readings.length - 1];

  // ------------------------------------------------
  // TITLE - EXTRA LEFT MARGIN
  // ------------------------------------------------

  const titleRow = w.addStack();
  titleRow.setPadding(0, 8, 0, 0);

  const title = titleRow.addText("PLAATO FERMENTATION");
  title.font = Font.boldSystemFont(12);
  title.textColor = WHITE;

  w.addSpacer(7);

  // ------------------------------------------------
  // TOP SNAPSHOT - TWO COMPACT CENTRED BOXES
  // ------------------------------------------------

  const cards = w.addStack();
  cards.layoutHorizontally();
  cards.centerAlignContent();
  cards.spacing = 10;

  cards.addSpacer();

  function addReadingBox(parent, label, value, colour) {
    const box = parent.addStack();
    box.layoutVertically();
    box.centerAlignContent();
    box.backgroundColor = new Color("#24543D");
    box.cornerRadius = 9;
    box.setPadding(7, 7, 7, 7);
    box.size = new Size(125, 57);

    const heading = box.addText(label);
    heading.font = Font.systemFont(9);
    heading.textColor = WHITE;
    heading.centerAlignText();

    box.addSpacer(3);

    const reading = box.addText(value);
    reading.font = Font.boldSystemFont(19);
    reading.textColor = colour;
    reading.centerAlignText();

    return box;
  }

  addReadingBox(
    cards,
    "TEMPERATURE",
    `${latest.temperature.toFixed(2)} °C`,
    GREEN
  );

  addReadingBox(
    cards,
    "BUBBLES / MIN",
    latest.bubbles.toFixed(1),
    ORANGE
  );

  cards.addSpacer();

  w.addSpacer(7);

  // ------------------------------------------------
  // ORIGINAL COMBINED GRAPH
  // ------------------------------------------------

  const graph = drawGraph(readings);
  const graphImage = w.addImage(graph);

  graphImage.imageSize = new Size(340, 190);
  graphImage.resizable = true;

  w.addSpacer(3);

  // ------------------------------------------------
  // CENTRED LEGEND
  // ------------------------------------------------

  const legend = w.addStack();
  legend.layoutHorizontally();

  legend.addSpacer();

  const greenDot = legend.addText("●");
  greenDot.textColor = GREEN;
  greenDot.font = Font.systemFont(9);

  legend.addSpacer(3);

  const tempLegend = legend.addText("Temperature");
  tempLegend.textColor = WHITE;
  tempLegend.font = Font.systemFont(9);

  legend.addSpacer(12);

  const orangeDot = legend.addText("●");
  orangeDot.textColor = ORANGE;
  orangeDot.font = Font.systemFont(9);

  legend.addSpacer(3);

  const bubbleLegend = legend.addText("Bubbles/min");
  bubbleLegend.textColor = WHITE;
  bubbleLegend.font = Font.systemFont(9);

  legend.addSpacer();

  // Refresh
  w.refreshAfterDate = new Date(Date.now() + 5 * 60 * 1000);

} catch (error) {
  const titleRow = w.addStack();
  titleRow.setPadding(0, 8, 0, 0);

  const title = titleRow.addText("PLAATO FERMENTATION");
  title.font = Font.boldSystemFont(12);
  title.textColor = WHITE;

  w.addSpacer(8);

  const message = w.addText("Unable to load readings");
  message.textColor = WHITE;
  message.font = Font.systemFont(11);

  const detail = w.addText(String(error));
  detail.textColor = WHITE;
  detail.font = Font.systemFont(9);
}

// LARGE widget - preserve original presentation
if (config.runsInWidget) {
  Script.setWidget(w);
} else {
  await w.presentLarge();
}

Script.complete();


// ==================================================
// GRAPH DRAWING
// ==================================================

function drawGraph(readings) {

  // ORIGINAL GRAPH DIMENSIONS - DO NOT CHANGE
  const width = 340;
  const height = 190;

  // Adjusted graph margins
  const left = 44;
  const right = 40;
  const top = 13;
  const bottom = 30;

  const plotWidth = width - left - right;
  const plotHeight = height - top - bottom;

  const ctx = new DrawContext();
  ctx.size = new Size(width, height);
  ctx.opaque = false;
  ctx.respectScreenScale = true;

  const temperatures = readings.map(r => r.temperature);
  const bubbles = readings.map(r => r.bubbles);

  let minTemp = Math.floor(Math.min(...temperatures) - 1);
  let maxTemp = Math.ceil(Math.max(...temperatures) + 1);

  let minBubble = Math.max(0, Math.floor(Math.min(...bubbles) - 2));
  let maxBubble = Math.ceil(Math.max(...bubbles) + 2);

  if (minTemp === maxTemp) maxTemp++;

  // Make the temperature range divisible by the 4 grid steps so the
  // axis labels are whole numbers and never repeat (e.g. "24" twice)
  const tempSpan = Math.ceil((maxTemp - minTemp) / 4) * 4;
  maxTemp = minTemp + tempSpan;
  if (minBubble === maxBubble) maxBubble++;

  function xPos(i) {
    return left + (i / (readings.length - 1)) * plotWidth;
  }

  function tempY(value) {
    return top +
      ((maxTemp - value) / (maxTemp - minTemp)) * plotHeight;
  }

  function bubbleY(value) {
    return top +
      ((maxBubble - value) / (maxBubble - minBubble)) * plotHeight;
  }

  // GRID AND AXIS LABELS
  for (let i = 0; i <= 4; i++) {

    const y = top + (i / 4) * plotHeight;

    const gridPath = new Path();
    gridPath.move(new Point(left, y));
    gridPath.addLine(new Point(width - right, y));

    ctx.addPath(gridPath);
    ctx.setStrokeColor(GRID);
    ctx.setLineWidth(0.6);
    ctx.strokePath();

    const tempLabel =
      (maxTemp - (i / 4) * (maxTemp - minTemp)).toFixed(0);

    const bubbleLabel =
      (maxBubble - (i / 4) * (maxBubble - minBubble)).toFixed(0);

    // LEFT AXIS - TEMPERATURE
    ctx.setTextColor(WHITE);
    ctx.setFont(Font.systemFont(9));
    ctx.setTextAlignedRight();

    ctx.drawTextInRect(
      tempLabel,
      new Rect(0, y - 6, left - 5, 13)
    );

    // RIGHT AXIS - BUBBLES
    ctx.setTextColor(WHITE);
    ctx.setFont(Font.systemFont(9));
    ctx.setTextAlignedLeft();

    ctx.drawTextInRect(
      bubbleLabel,
      new Rect(width - right + 5, y - 6, right - 5, 13)
    );
  }

  // TEMPERATURE LINE
  drawSeries(
    ctx,
    readings.map((r, i) =>
      new Point(xPos(i), tempY(r.temperature))
    ),
    GREEN,
    2
  );

  // BUBBLES LINE
  drawSeries(
    ctx,
    readings.map((r, i) =>
      new Point(xPos(i), bubbleY(r.bubbles))
    ),
    ORANGE,
    2
  );

  // DATA POINT MARKERS
  readings.forEach((r, i) => {
    drawMarker(ctx, xPos(i), tempY(r.temperature), GREEN);
    drawMarker(ctx, xPos(i), bubbleY(r.bubbles), ORANGE);
  });

  // X AXIS - TIMESTAMPS
  const first = formatTime(readings[0].timestamp);
  const middle = formatTime(
    readings[Math.floor((readings.length - 1) / 2)].timestamp
  );
  const last = formatTime(
    readings[readings.length - 1].timestamp
  );

  ctx.setTextColor(WHITE);
  ctx.setFont(Font.systemFont(9));

  ctx.setTextAlignedLeft();
  ctx.drawTextInRect(
    first,
    new Rect(left, height - 19, 55, 13)
  );

  ctx.setTextAlignedCenter();
  ctx.drawTextInRect(
    middle,
    new Rect(width / 2 - 28, height - 19, 56, 13)
  );

  ctx.setTextAlignedRight();
  ctx.drawTextInRect(
    last,
    new Rect(width - right - 55, height - 19, 55, 13)
  );

  return ctx.getImage();
}


// ==================================================
// GRAPH HELPERS
// ==================================================

function drawSeries(ctx, points, colour, thickness) {

  if (points.length < 2) return;

  const path = new Path();
  path.move(points[0]);

  for (let i = 1; i < points.length; i++) {
    path.addLine(points[i]);
  }

  ctx.setStrokeColor(colour);
  ctx.setLineWidth(thickness);
  ctx.addPath(path);
  ctx.strokePath();
}


function drawMarker(ctx, x, y, colour) {

  const radius = 2;

  ctx.setFillColor(colour);

  ctx.fillEllipse(
    new Rect(
      x - radius,
      y - radius,
      radius * 2,
      radius * 2
    )
  );
}


function formatTime(timestamp) {
  return new Date(timestamp * 1000).toLocaleTimeString(
    "en-IE",
    {
      hour: "2-digit",
      minute: "2-digit",
      hour12: false
    }
  );
}
