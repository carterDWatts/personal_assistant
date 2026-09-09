import asyncio
import base64
import io
import json
import os
import uuid
import unittest
from unittest.mock import patch, MagicMock
import psycopg
from PIL import Image, ImageDraw
from engine.db import jsonb
from engine.images import Images, normalized, tool_content
from engine.tools import ToolError, Tools
from engine.engine import Session
from engine.conversation import Conversation
from tst.helpers import MapTest, FakeRuntime, FakeTerminal, say


def picture():
    image=Image.new('RGB',(240,160),'white');draw=ImageDraw.Draw(image)
    draw.rectangle((15,15,225,145),fill='blue')
    out=io.BytesIO();image.save(out,format='PNG');return out.getvalue()


class images_test(MapTest):
    def setUp(self):
        super().setUp();self.map.execute('truncate assistant.owner,assistant.host cascade')
        self.owner,self.device=uuid.uuid4(),uuid.uuid4()
        self.map.execute('insert into assistant.owner(user_id) values(%s)',(self.owner,))
        self.client('register',{'name':'Test phone'})
        self.storage=MagicMock();self.storage.read.return_value=picture()
        self.storage.signed.return_value='https://example.invalid/signed-image'
        self.mock=patch('engine.images.Storage',return_value=self.storage);self.mock.start()
        self.images=Images(self.map)

    def tearDown(self):
        if getattr(self,'mock',None):self.mock.stop()
        if getattr(self,'map',None):self.map.execute('truncate assistant.owner,assistant.host cascade')
        super().tearDown()

    def client(self,action,args):
        return self.map.value('select public.assistant_client(%s,%s,%s,%s)',(self.owner,self.device,action,jsonb(args)))

    def test_image_input_is_owner_scoped_and_turn_retries_preserve_ids(self):
        image=self.images.save(picture(),'photo.png')
        args={'text':'What is this?','client_message_id':str(uuid.uuid4()),'images':[image['id']]}
        first=self.client('submit',args);self.assertEqual(first,self.client('submit',args))
        with self.assertRaisesRegex(psycopg.Error,'idempotency_conflict'):self.client('submit',{**args,'images':[]})
        with self.assertRaisesRegex(psycopg.Error,'invalid_request'):self.client('submit',{**args,'images':[str(uuid.uuid4())]})
        self.assertEqual(str(self.map.value('select images[1] from assistant.turns where id=%s',(first['turn_id'],))),image['id'])
        with self.assertRaisesRegex(psycopg.Error,'account_denied'):
            self.map.value('select public.assistant_image(%s,%s,%s,%s)',(uuid.uuid4(),self.device,'get',jsonb({'id':image['id']})))

    def test_invalid_or_oversized_images_are_rejected(self):
        for data in (b'<html>not an image</html>',b'x'*4000001):
            with self.assertRaises(ToolError):normalized(data)
        self.assertEqual(Image.open(io.BytesIO(normalized(picture()))).format,'JPEG')

    def test_tool_image_bytes_are_not_saved_as_transcript_text(self):
        image=self.images.save(picture())
        result=self.run_async(self.images.read({'id':image['id']}))
        text,blocks=tool_content(json.dumps(result))
        self.assertNotIn('_image_content',text);self.assertNotIn(blocks[0]['data'],text)
        self.assertEqual(blocks[0]['mime'],'image/jpeg')
        self.assertEqual(self.images.preview(image['id'])['url'],self.storage.signed.return_value)

    def test_images_survive_session_history_and_are_passed_as_visual_input(self):
        image=self.images.save(picture())
        class VisualRuntime(FakeRuntime):
            async def send(self,text,images=None):
                self.images=images
                async for event in super().send(text):yield event
        async def check():
            runtime=VisualRuntime([[say('A blue rectangle.')]]);session=Session(self.map,runtime,FakeTerminal([]),'image-test',auto_memory=False)
            await session.open()
            await session.send('What is here?',images=[image['id']]);await session.close()
            self.assertEqual(runtime.images[0]['id'],image['id'])
            tail=session.conv.tail(10);self.assertIn(image['id'],session.conv.seed_text(tail))
            rows=await session.tools.conversation_history({'query':'What is here?'})
            self.assertEqual(rows[0]['images'],[image['id']])
        self.run_async(check())

    @unittest.skipUnless(os.environ.get('ASSISTANT_LIVE_IMAGE_TEST')=='1','Opt-in subscription vision test')
    def test_subscription_models_read_actual_image_pixels(self):
        from engine.runtime import load
        async def check():
            for name in os.environ.get('ASSISTANT_LIVE_IMAGE_RUNTIMES','codex').split(','):
                runtime=load(name)();answer=[]
                try:
                    await runtime.open('Describe the image. Answer in one short sentence.',[])
                    async for event in runtime.send('What color is the rectangle?',images=[{'mime':'image/jpeg','data':base64.b64encode(normalized(picture())).decode()}]):
                        if event.kind=='assistant_text':answer.append(event.text)
                    self.assertIn('blue',' '.join(answer).lower(),name)
                finally:await runtime.close()
        self.run_async(check())
