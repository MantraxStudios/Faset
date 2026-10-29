// Introducciones escritas a mano para cada módulo de lib/std. Son opcionales: un módulo
// nuevo sin introducción se documenta igualmente con la API extraída del código.
import type { ComponentType } from "react";
import core from "./core.mdx";
import collections from "./collections.mdx";
import text from "./text.mdx";
import io from "./io.mdx";
import os from "./os.mdx";
import math from "./math.mdx";
import random from "./random.mdx";
import time from "./time.mdx";
import json from "./json.mdx";
import hash from "./hash.mdx";
import mem from "./mem.mdx";
import ui from "./ui.mdx";

export const intros: Record<string, ComponentType> = {
  core,
  collections,
  text,
  io,
  os,
  math,
  random,
  time,
  json,
  hash,
  mem,
  ui,
};
