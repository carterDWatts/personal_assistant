import io
import unittest
import numpy as np
from engine.voice.recognize import Recognizer, read_exact


class voice_test(unittest.TestCase):
    def test_audio_pipe_handles_fragmented_reads(self):
        class Fragmented(io.BytesIO):
            def read(self, size=-1): return super().read(min(size,2))
        self.assertEqual(read_exact(Fragmented(b'abcdefgh'),8),b'abcdefgh')
        self.assertIsNone(read_exact(io.BytesIO(),8))
        with self.assertRaises(ValueError): read_exact(Fragmented(b'abc'),8)

    def test_invalid_audio_is_rejected_before_decoding(self):
        recognizer=object.__new__(Recognizer)
        for rate,samples in [(0,np.zeros(100)),(999999,np.zeros(100)),(16000,np.array([float('nan')]))]:
            with self.assertRaises(ValueError): recognizer.accept(rate,samples)
