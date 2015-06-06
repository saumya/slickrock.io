package;

import abe.App;
import express.Middleware;
import express.Response;
import haxe.Json;
import haxe.Timer;
import js.Lib;
import thx.Dates.HaxeDateTools;

import js.Node;
import js.node.Fs;
import js.Error;
import js.Node;

import express.Express;

using StringTools;

class Main {

	public static var db: Array<String> = [];
	public static var tokens: Array<Int> = [];	
	static var typingTimers: Map<String, Array<Timer>>;
	
	static var textDB: String = '';
	
	public static var rooms: Rooms;
	
	var MongoClient: Dynamic;
	var mongoUrl = '';
	static var mongodb: Dynamic;
		
	function new() {
		_setupMongo();
		rooms = new Rooms();
		typingTimers = new Map();
		
		var app = new App();
		app.router.register(new RouteHandler());
		var port = Node.process.env.get('PORT');
		app.http(port != null? Std.parseInt(port) : 9998);
		
		app.router.serve('/bin', './bin');
	}
	
	function _setupMongo() {
		MongoClient = Lib.require('mongodb').MongoClient;
		
		mongoUrl = Node.process.env['MONGOLAB_URL'];
		MongoClient.connect(mongoUrl, function(err, db) {
			if (err != null) {
				trace(err);
			}
			mongodb = db;
			_parseMessages();
			_test('testroom', 0, 'testing');
			_test('testr', 5, 'ting');
			_test('testroom', 1, 'testing1');
		});
	}
	
	function _test(room: String, id: Int, message: String) {
		if (!Main.rooms.exists(room)) {
			Main.rooms.set(room, {
				messages: new Array<Message>(),
				lock: null,
				owner: null,
				typing: []
			});
		}
		
		Main.emptyTyping(room, id);
		
		Main.rooms.get(room).messages.push( { text: message, id: id } );
		Main.saveMessage( { text: message, id: id, room: room} );
	}
	
	public static function clearTyping(room: String, id: Int) {
		if (typingTimers[room] == null) {
			typingTimers[room] = new Array();
		}
		if(typingTimers[room][id] == null) {
			var timer = new Timer(3000);
			timer.run = emptyTyping.bind(room, id);
			typingTimers[room][id] = timer;
		}
		else {
			resetTypingTimer(room, id);
		}
	}
	
	public static function resetTypingTimer(room: String, id: Int) {
		if (typingTimers[room] == null) {
			typingTimers[room] = new Array();
		}
		typingTimers[room][id].run = emptyTyping.bind(room, id);
	}
	
	public static function emptyTyping(room: String, id: Int) {
		rooms[room].typing.remove(id);
	}
	
	static function _parseMessages() {
		mongodb.collection('roominfo').find().toArray(function(e, r) {
			if (e != null) {
				trace(e);
				return;
			}
			var roominfo: Array<RoomInfo> = cast r;
			for (r in roominfo) {
				if (!rooms.exists(r._id)) {
					rooms.set(r._id, {
						messages: new Array<Message>(),
						lock: null,
						owner: null,
						typing: []
					});
				}
				rooms.get(r._id).lock = r.lock;
				rooms.get(r._id).owner = r.owner;
			}
		});
		mongodb.collection('messages').find().sort( { _id:1 } ).toArray(function(e, r) {
			if (e != null) {
				trace(e);
				return;
			}
			var messages: Array<MessageObject> = cast r;
			for (m in messages) {
				if (!rooms.exists(m.room)) {
					rooms.set(m.room, {
						messages: new Array<Message>(),
						lock: null,
						owner: null,
						typing: []
					});
				}
				rooms.get(m.room).messages.push( { text: m.text, id: m.id } );
			}
		});
		mongodb.collection('tokens').find().toArray(function(e, r) {
			if (e != null) {
				trace(e);
				return;
			}
			var tokenos: Array<TokenObject> = cast r;
			for (t in tokenos) {
				tokens[t._id] = t.token;
			}
		});
	}
	
	public static function saveMessage(msg: MessageObject) {
		if (mongodb != null) {
			mongodb.collection('messages').insertOne(msg, function(e, r) {
				if (e != null) {
					trace(e);
				}
			});
		}
		else {
			trace('mongo null');
		}
	}
	
	public static function roomInfo(roomInfo: RoomInfo) {
		mongodb.collection('roominfo').save(roomInfo);
	}
	
	public static function saveToken(token: TokenObject) {
		mongodb.collection('tokens').save(token);
	}
	
	public static function main() {
		new Main();
	}
}

class RouteHandler implements abe.IRoute {
	@:get('/')
	function index() {
		_serveHtml('bin/index.html', function(e, d) {
			if (e == null) {
				var withRoom: String = '';
				var startBody = d.indexOf('head') + 6;
				withRoom = d.substring(0, startBody) + '\n\t<script>var room = "base"</script>\n' + d.substr(startBody + 1);
				response.setHeader('Access-Control-Allow-Origin', '*');
				response.send(withRoom);
			}
		});
	}
	
	@:get('/:room')
	function chatroom(room: String) {
		room = room.toLowerCase();
		_serveHtml('bin/index.html', function(e, d) {
			if (e == null) {
				var withRoom: String = '';
				var startBody = d.indexOf('head') + 6;
				withRoom = d.substring(0, startBody) + '\n\t<script>var room = "$room"</script>\n' + d.substr(startBody + 1);
				response.setHeader('Access-Control-Allow-Origin', '*');
				response.send(withRoom);
			}
		});
	}
	
	@:post('/chat/:message/:room/:id/:privateID/:token')
	function sendMessage(message: String, room: String, id: Int, privateID: Int, token: Int) {
		room = room.toLowerCase();
		_sendMessage(response, message, room, null, id, privateID, token);
	}
	
	@:post('/chat/:message/:room/:password/:id/:privateID/:token')
	function sendMessageWithPass(message: String, room: String, password: String, id: Int, privateID: Int, token: Int) {
		room = room.toLowerCase();
		_sendMessage(response, message, room, password, id, privateID, token);
	}

	function _sendMessage(response: Response, message: String, room: String, password: String, id: Int, privateID: Int, token: Int) {
		if(Main.tokens[privateID] == token) {
			if (!Main.rooms.exists(room)) {
				Main.rooms.set(room, {
					messages: new Array<Message>(),
					lock: null,
					owner: null,
					typing: []
				});
			}
			
			Main.emptyTyping(room, id);
			
			if(Main.rooms.get(room).lock == null || Main.rooms.get(room).lock == password) {
				Main.rooms.get(room).messages.push( { text: message, id: id } );
				Main.saveMessage( { text: message, id: id, room: room} );
			}
			response.setHeader('Access-Control-Allow-Origin', '*');
			response.send('success');
			return;
		}
		response.setHeader('Access-Control-Allow-Origin', '*');
		response.send('failed');
	}
	
	@:post('/api/gettoken/:privateID') 
	function getToken(privateID: Int) {
		Main.tokens[privateID] = Std.int(Math.random() * 0xFFFFFF);
		Main.saveToken( { _id: privateID, token: Main.tokens[privateID] } );
		response.setHeader('Access-Control-Allow-Origin', '*');
		response.send(Std.string(Main.tokens[privateID]));
	}
	
	@:get('/api/typing/:room/:id') 
	@:post('/api/typing/:room/:id') 
	function typing(room: String, id: Int) {
		if (Main.rooms.get(room).typing.indexOf(id) == -1) {
			Main.rooms.get(room).typing.push(id);
			Main.clearTyping(room, id);
		}
		else {
			Main.resetTypingTimer(room, id);
		}
		response.setHeader('Access-Control-Allow-Origin', '*');
		response.send('needs a response');
	}

	@:post('/api/checkvalid/:privateID/:token') 
	function checkValid(privateID: Int, token: Int) {
		var value = 'invalid';
		if (Main.tokens[privateID] == token) {
			value = 'valid';
		}
		response.setHeader('Access-Control-Allow-Origin', '*');
		response.send(value);
	}
	
	@:post('/api/lock/:room/:privateID/:password')
	function lockRoom(room: String, privateID: Int, password: String) {
		room = room.toLowerCase();
		var roomE = Main.rooms.get(room);
		if (roomE.owner == privateID ||  (roomE.messages.length == 0 && roomE.lock == null)) {
			roomE.lock = password;
			roomE.owner = privateID;
			Main.roomInfo( { _id: room, lock: password, owner: privateID } );
			response.setHeader('Access-Control-Allow-Origin', '*');
			response.send('locked');
			return;
		}
		response.setHeader('Access-Control-Allow-Origin', '*');
		response.send('failed');
	}
	
	@:post('/api/unlock/:room/:privateID')
	function unlockRoom(room: String, privateID: Int) {
		room = room.toLowerCase();
		var roomE = Main.rooms.get(room);
		if (roomE.owner == privateID) {
			roomE.lock = null;
			Main.roomInfo( { _id: room, lock: null, owner: Main.rooms[room].owner } );
			response.setHeader('Access-Control-Allow-Origin', '*');
			response.send('unlocked');
			return;
		}
		response.setHeader('Access-Control-Allow-Origin', '*');
		response.send('failed');
	}
	
	@:post('/api/claim/:room/:privateID')
	function claimRoom(room: String, privateID: Int) {
		room = room.toLowerCase();
		var roomE = Main.rooms.get(room);
		if (roomE.owner == null &&  roomE.messages.length == 0) {
			roomE.owner = privateID;
			Main.roomInfo( { _id: room, owner: privateID } );
			response.setHeader('Access-Control-Allow-Origin', '*');
			response.send('claimed');
			return;
		}
		response.setHeader('Access-Control-Allow-Origin', '*');
		response.send('failed');
	}
	
	@:get('/api/:room/:lastID')
	@:post('/api/:room/:lastID')
	function getMessages(room: String, lastID: Int) {
		room = room.toLowerCase();
		_getMessages(response, room, null, lastID);
	}
	
	@:post('/api/:room/:password/:lastID')
	function getMessagesWithPass(room: String, password: String, lastID: Int) {
		room = room.toLowerCase();
		_getMessages(response, room, password, lastID);
	}
	
	function _getMessages(response: Response, room: String, password: String, lastID: Int) {
		if (!Main.rooms.exists(room)) {
			Main.rooms.set(room, {
				messages: new Array<Message>(),
				lock: null,
				owner: null,
				typing: []
			});
		}
		
		if(Main.rooms.get(room).lock == null || Main.rooms.get(room).lock == password) {
			var messages: MessageData = {
				messages: {
					messages: new Array<Message>(),
					lock: null,
					owner: null,
					typing: Main.rooms.get(room).typing
				},
				lastID: Main.rooms.get(room).messages.length - 1
			};

			if (lastID < Main.rooms.get(room).messages.length - 1) {
				for (i in (lastID + 1)...Main.rooms.get(room).messages.length) {
					messages.messages.messages.push(Main.rooms.get(room).messages[i]);
				}
			}
			response.setHeader('Access-Control-Allow-Origin', '*');
			response.setHeader('Content-Type', 'application/json');
			response.send(messages);
		}
		else {
			response.setHeader('Access-Control-Allow-Origin', '*');
			if(password != null) { 
				response.send('password');
			}
			else {
				response.send('locked');
			}
		}
	}
	
	function _serveHtml(path: String, handler: Error->String->Void) {
		Fs.readFile(path, { encoding: 'utf8' }, handler);
	}
}
