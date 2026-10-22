#!/usr/bin/env python3
"""Portable native ABT completion contract regression tests.

Runs the production forwarding call and verification expression as C because
Foundation and the iOS runtime are unavailable on the analysis host. This tests
arguments and the success boundary; it does not simulate native networking.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src/Runtime/WAGRABPropsABTLiveService.m'


def c_run(body):
    with tempfile.TemporaryDirectory(prefix='wagr_abt_completion_') as directory:
        source = Path(directory) / 'contract.c'
        binary = Path(directory) / 'contract'
        source.write_text('#include <assert.h>\n#include <stdbool.h>\n#include <stddef.h>\n' + body)
        compiled = subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                                   str(source), '-o', str(binary)], text=True, capture_output=True)
        if compiled.returncode:
            raise AssertionError('Production completion contract does not compile:\n' + compiled.stderr)
        run = subprocess.run([str(binary)], text=True, capture_output=True)
        if run.returncode:
            raise AssertionError('Production completion contract rejected fixture:\n' + run.stderr)


class NativeCompletionContract(unittest.TestCase):
    def test_forwards_success_change_and_config_key_without_changing_them(self):
        """Losing any of the native callback arguments must fail this fixture."""
        text = SOURCE.read_text()
        lower = text.split('static void LowerHook(', 1)[1].split('static id RequestInitHook(', 1)[0]
        forward = re.search(r'if\s*\(originalCompletion\)\s*originalCompletion\([^;]*;', lower)
        self.assertIsNotNone(forward, 'Native completion forwarding is missing')
        c_run('''
static bool gotSuccess, gotChanged;
static void *gotKey;
static int calls;
static void record(bool success, bool didChange, void *configKey) {
    gotSuccess = success; gotChanged = didChange; gotKey = configKey; calls++;
}
static void forward(void (*originalCompletion)(bool, bool, void *),
                    bool success, bool didChange, void *configKey) {
    ''' + forward.group(0) + '''
}
int main(void) {
    int key;
    forward(record, true, false, &key);
    assert(calls == 1 && gotSuccess && !gotChanged && gotKey == &key);
    forward(record, false, true, NULL);
    assert(calls == 2 && !gotSuccess && gotChanged && gotKey == NULL);
    forward(NULL, false, false, NULL);
    assert(calls == 2);
    return 0;
}
''')

    def test_failed_native_completion_cannot_be_verified_from_other_proof(self):
        """Even perfect response/store evidence cannot override native failure."""
        text = SOURCE.read_text()
        final = text.split('static NSDictionary *BuildFinalResult(void)', 1)[1].split(
            'NSDictionary<NSString *, id> *WAGRABPropsABTAccountSnapshotDocument(', 1)[0]
        assignment = re.search(r'BOOL verified\s*=.*?;', final, re.S)
        self.assertIsNotNone(assignment)
        expression = assignment.group(0).replace('BOOL verified', 'bool verified')
        c_run('''
#define nil NULL
static bool verify(bool nativeCompletionObserved, bool nativeCompletionSucceeded) {
    bool exactRequestSucceeded = true;
    bool correlatedHandler = true, handlerErrorPresent = false, exactStore = true;
    bool metadataMatches = true, nativeBranchMatches = true, wireShapeMatches = true;
    bool fullResponseConfirmed = true, resetHashRefilled = true;
    int store; void *after = &store;
    (void)nativeCompletionSucceeded;
    ''' + expression + '''
    return verified;
}
int main(void) {
    assert(!verify(true, false));
    assert(!verify(false, true));
    assert(!verify(false, false));
    assert(verify(true, true));
    return 0;
}
''')

    def test_native_failure_has_explicit_failure_outcome(self):
        """A completed false result must not be presented as a store mismatch."""
        text = SOURCE.read_text()
        final = text.split('static NSDictionary *BuildFinalResult(void)', 1)[1]
        branches = final.split('NSString *outcome = nil;', 1)[1].split(
            'NSString *effectiveSource', 1)[0]
        branches = branches.replace('@"', '"').replace('didFailEvents.count', '0')
        c_run('''
#include <string.h>
int main(void) {
    bool verified = false, nativeCompletionObserved = true, nativeCompletionSucceeded = false;
    bool exactRequestSucceeded = true, correlatedHandler = true, handlerErrorPresent = false;
    bool exactStore = true, nativeBranchMatches = true, wireShapeMatches = true;
    bool fullResponseConfirmed = true, resetHashRefilled = true;
    const char *outcome = NULL;
    ''' + branches + '''
    assert(strcmp(outcome, "native_completion_reported_failure") == 0);
    return 0;
}
''')

    def test_wrapper_declares_the_same_three_arguments_as_native(self):
        """The captured block ABI must agree with the native block call site."""
        text = SOURCE.read_text()
        typedef = re.search(r'typedef void \(\^(WAGRABTNativeCompletion)\)(\([^;]+\));', text)
        self.assertIsNotNone(typedef, 'Native typed completion block declaration is missing')
        parameters = typedef.group(2).replace('BOOL', 'bool').replace('id configKey', 'void *configKey')
        wrapper = re.search(r'wrappedCompletion\s*=\s*\^(\([^)]*\))\s*\{', text)
        self.assertIsNotNone(wrapper, 'Wrapper does not declare the native callback arguments')
        wrapper_parameters = wrapper.group(1).replace('BOOL', 'bool').replace('id configKey', 'void *configKey')
        c_run('''
typedef void (*Expected)(bool, bool, void *);
typedef void (*Actual)''' + parameters + ';\n' + '''
static void wrapper''' + wrapper_parameters + ''' {
    (void)success; (void)didChange; (void)configKey;
}
int main(void) {
    Actual actual = wrapper;
    Expected expected = actual;
    expected(false, false, NULL);
    return 0;
}
''')


if __name__ == '__main__':
    unittest.main(verbosity=2)
