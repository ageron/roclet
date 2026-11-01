import {test} from 'node:test';
import assert from 'node:assert/strict';
import {isVisibleDiagnostic} from '../web/compiler-tools.mjs';

const empirical=noun=>`This ${noun} was not taken during compile-time evaluation.\nNote: This warning is empirical; it only describes the compile-time evaluation that ran for this definition.`;
test('empirical branch warnings are hidden for both mapped and raw compiler diagnostics',()=>{
  for(const noun of ['match alternative','if branch']) {
    assert.equal(isVisibleDiagnostic({severity:'warning',title:'Unused Branch',message:empirical(noun)}),false);
    assert.equal(isVisibleDiagnostic({severity:'warning',code:'roc-check',message:`**Unused Branch**\n${empirical(noun)}`}),false);
  }
});
test('errors and actionable warnings remain visible, including genuine unreachable branches',()=>{
  for(const diagnostic of [
    {severity:'error',title:'Unused Branch',message:empirical('match alternative')},
    {severity:'warning',title:'Unused Variable',message:'The variable is never used.'},
    {severity:'warning',title:'Unused Branch',message:'This branch can never be reached.'},
    {severity:'warning',title:'Unreachable Pattern',message:'This alternative is covered by an earlier pattern.'},
    {severity:'error',code:'roc-check',message:'**Type Mismatch**'},
  ])assert.equal(isVisibleDiagnostic(diagnostic),true);
});
