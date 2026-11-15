/**
 * 输出侧拒答识别。
 *
 * 上游没有结构化信号(2026-11-14 实测:命中输出审核时 finish_reason 仍是 `stop`、
 * safety_tokens 为 0,模型只是在正文里说「这个我不能写」「抱歉,我无法提供…」,
 * 见 docs/HANDOFF-M2.md §0.1),所以这里做启发式识别,只用于给客户端打「模型拒答」标识,
 * 不改写、不隐藏模型输出。
 *
 * 判据刻意收紧,宁可漏判不可误判:
 *  - 只在回答很短(≤400 字)时识别 —— 长回答里出现「我无法提供」通常是转述内容;
 *  - 只在开头 80 字内匹配 —— 拒答都是开门见山;
 *  - 关键词模式来自 2026-11-15 真实 key 的拒答原文(见 server/test 里的 fixture)。
 */

export type SafetySource = 'input' | 'output';

export interface SafetyFlag {
  source: SafetySource;
  /** 给用户看的简短原因 */
  reason: string;
}

const MAX_REFUSAL_CHARS = 400;
const HEAD_WINDOW = 80;

/** 否定说法:实测模型会混用「不能/没法/无法/不会」 */
const NEGATION = '(?:没法|无法|不能|不可以|不会|不方便)';
/** 被拒的动作:实测会换个动词说("不能写"/"不能教"),所以列宽一点 */
const ACTION =
  '(?:写|教|做|给|帮|提供|协助|回答|生成|完成|参与|满足|支持|透露|告诉|执行|说|讲)';

const REFUSAL_PATTERNS: RegExp[] = [
  // 「这个我不能写。」「这个我也不能教。」「这个我没法帮你写。」
  new RegExp(`(?:这个|这|这些|该|此)[^。，,]{0,6}(?:也|都)?${NEGATION}${ACTION}`),
  // 「我无法提供…」「我不会写任何开锁手法」
  new RegExp(`(?:我|本人)(?:也|都)?${NEGATION}${ACTION}`),
  // 「这个忙我帮不了」「我教不了」
  /(?:帮|写|教|做|提供|回答|生成)(?:不了|不到|不出)/,
  /抱歉[，,、]?\s*(?:我|这个)?\s*(?:没法|无法|不能|没办法|不便)/,
  /(?:违反|不符合|触及)(?:了)?(?:相关)?(?:政策|规定|准则|法律)/,
  /作为(?:一个)?(?:AI|人工智能|语言模型)[，,]?\s*我(?:没法|无法|不能)/,
  /\bI(?:'m| am) (?:sorry|afraid)\b/i,
  /\bI (?:can(?:no|')?t|am unable to|won't|will not) (?:help|assist|provide|comply|do that|continue|write|teach)\b/i,
  /\b(?:can(?:no|')?t|unable to) (?:help|assist|provide) (?:with )?(?:that|this)\b/i,
];

/** 命中返回标识,否则 null。 */
export function detectOutputRefusal(text: string): SafetyFlag | null {
  const trimmed = text.trim();
  if (trimmed === '' || trimmed.length > MAX_REFUSAL_CHARS) return null;
  const head = trimmed.slice(0, HEAD_WINDOW);
  for (const pattern of REFUSAL_PATTERNS) {
    if (pattern.test(head)) {
      return { source: 'output', reason: '模型以内容安全为由拒答' };
    }
  }
  return null;
}
