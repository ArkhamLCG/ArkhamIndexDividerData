import path from 'node:path';
import 'dotenv/config';
import fs from 'node:fs';
import sharp from 'sharp';
import type { ArkhamDivider } from 'arkham-divider-data';

const ROOT = process.cwd();
const imagesDir = path.join(ROOT, 'public', 'images');
const investigatorsDir = path.join(imagesDir, 'investigator');

const code = process.argv[2];
const overwrite = process.argv.includes(':overwrite');

if (!code) {
  throw new Error('story code is not set');
}

const scenarioDir = path.join(imagesDir, 'scenario', code);
if (!fs.existsSync(scenarioDir)) {
  fs.mkdirSync(scenarioDir, { recursive: true });
}

const url = process.env.ARKHAM_DIVIDER_DATA_URL;

if (!url) {
  throw new Error('ARKHAM_DIVIDER_DATA_URL is not set');
}

const response = await fetch(url);
const { stories }: ArkhamDivider.Core = await response.json();

const story = stories.find((story) => story.code === code);

if (!story) {
  throw new Error(`story with code ${code} not found`);
}

const { investigators, return_to_code } = story;

const returnStory = stories.find((story) => story.code === return_to_code);

const returnEncounters = returnStory?.encounter_sets ?? []

const encounterSets = [
  ...story.encounter_sets,
  ...returnEncounters
];

const scenarioEncounters = [
  ...story.scenario_encounter_sets,
  ...returnStory?.scenario_encounter_sets ?? [],
]

const codes = [
  ...encounterSets,
  ...scenarioEncounters,
  ...scenarioEncounters.map((code) => `${code}-encounter`),
]

const placeholders = [
  {
    orientation: 'horizontal',
    placeholder: await generatePlaceholder(1098, 632),
  },
  {
    orientation: 'vertical',
    placeholder: await generatePlaceholder(839, 910),
  }
];

for (const code of codes) {
  for (const placeholder of placeholders) {
    const dir = path.join(scenarioDir, placeholder.orientation);

    const filename = path.join(dir, `${code}.avif`)

    if (fs.existsSync(filename) && !overwrite) {
      console.log(`placeholder ${filename} already exists`);
      continue;
    }

    if (!fs.existsSync(dir)) {
      console.log(`directory ${dir} created`);
      fs.mkdirSync(dir, { recursive: true });
    }

    fs.writeFileSync(filename, placeholder.placeholder);
    console.log(`placeholder ${filename} created`);
  }
}

for (const investigator of investigators) {

  for (const placeholder of placeholders) {
    const dir = path.join(investigatorsDir, placeholder.orientation);

    if (!fs.existsSync(dir)) {
      console.log(`directory ${dir} created`);
      fs.mkdirSync(dir, { recursive: true });
    }

    const filename = path.join(dir, `${investigator.code}.avif`)
    if (fs.existsSync(filename) && !overwrite) {
      console.log(`placeholder ${filename} already exists`);
      continue;
    }
  
    fs.writeFileSync(filename, placeholder.placeholder);
    console.log(`placeholder ${filename} created`);
  }
}

async function generatePlaceholder(width: number, height: number): Promise<Buffer> {
  const margin = 36;
  const leftLineX = margin;
  const rightLineX = width - margin - 1;
  const linesSvg = Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}">` +
      `<rect x="${leftLineX}" y="0" width="1" height="${height}" fill="rgb(255, 0, 0)"/>` +
      `<rect x="${rightLineX}" y="0" width="1" height="${height}" fill="rgb(255, 0, 0)"/>` +
      `</svg>`,
  );

  return sharp({
    create: {
      width,
      height,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    },
  })
    .composite([{ input: linesSvg, left: 0, top: 0 }])
    .avif()
    .toBuffer();
}