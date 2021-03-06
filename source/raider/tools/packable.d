/**
 * Yet another serialiser.
 * 
 * Serialisation of objects, also known as marshalling, persisting, 
 * flattening, pickling and shelving, is referred to here as 'packing'.
 * 
 * Mainly because it's shorter and sounds (slightly) less violent.
 * 
 * Packable provides (a)synchronous packing and unpacking of objects,
 * to and from files and archives. To participate, a class implements 
 * the Packable interface. A struct (which lacks virtual dispatch) 
 * defines toPack and fromPack, resolved at compile time.
 * 
 * Pack progress is tracked by how many bytes have been processed.
 * If a packable implementation has minimal computation and is close 
 * to being a direct binary dump, estimatePackSize can return 0. This 
 * indicates toPack should be used to obtain the exact size, via a 
 * dry run.
 * 
 * If an object has a complex serialised form (e.g. image and sound
 * formats) with a processor-intensive toPack, it may implement 
 * estimatePackSize to return a non-zero value. This will eliminate 
 * the first call to toPack. The estimated value is written into 
 * the pack and also used for unpacking.
 * 
 * toPack and fromPack may throw, but must leave a valid object in
 * their wake. They may catch and rethrow or use scope(failure) with
 * exceptions thrown by the Pack methods, but must not silence them.
 * 
 * This system does not use GC memory and cannot keep GC allocated
 * objects alive. All participating objects must use tool.reference.
 */

module raider.tools.packable;

import std.traits;
import derelict.physfs.physfs;
import raider.tools.stream;
import raider.tools.array;
import raider.tools.reference;

interface Packable
{
	void toPack(P!Pack);
	void fromPack(P!Pack);
	uint estimatePackSize();
	
	/**
	 * Save packable to file.
	 * 
	 * Opens a file with the specified filename and packs the object into it.
	 * If blocking, executes in current thread and throws exceptions.
	 * If non-blocking, executes in worker thread and returns a Pack for 
	 * checking progress and exceptions.
	 * 
	 * Do not operate on the same packable in multiple threads.
	 */
	final R!Pack save(string filename, bool block = true)
	{
		R!Pack pack = New!Pack(R!Packable(this), cast(R!Stream)New!FileStream(filename, Stream.Mode.Write));
		pack.execute(block);
		return pack;
	}
	
	/**
	 * Load packable from file.
	 * 
	 * Opens a file with the specified filename and unpacks the object from it.
	 * If blocking, executes in current thread and throws exceptions.
	 * If non-blocking, executes in worker thread and returns a Pack for 
	 * checking progress and exceptions.
	 * 
	 * Do not operate on the same packable in multiple threads.
	 */
	final R!Pack load(string filename, bool block = true)
	{
		R!Pack pack = New!Pack(R!Packable(this), cast(R!Stream)New!FileStream(filename, Stream.Mode.Read));
		pack.execute(block);
		return pack;
	}
}

/**
 * Unit of packing work.
 */
final class Pack
{
private:
	R!Packable packable;
	R!Stream stream;
	uint streamStart;
	uint packSize;
	bool _ready;
	Exception _exception;
	string _activity;

public:
	/**
	 * Construct a pack.
	 */
	this(R!Packable packable, R!Stream stream)
	{
		this.packable = packable;
		this.stream = stream;
		streamStart = 0;
		packSize = 0;
		_ready = false;
		_exception = null;
		_activity = "nothing";
	}
	
	/**
	 * Runs the pack or dispatches it to a worker.
	 */
	void execute(bool block)
	{
		if(block)
		{
			run;
			if(_exception) throw _exception;
		}
		else
		{
			//TODO Anything but taskPool.put(task)
			//Note, the task queue must receive a strong reference.
			//The user may discard the Task.

			run;
		}
	}
	
	void run()
	{
		try
		{
			if(packing)
			{
				streamStart = stream.bytesWritten;
				packSize = packable.estimatePackSize;
				if(packSize == 0) packSize = calculatePackSize;
				write(packSize);
				packable.toPack(P!Pack(this));
			}
			else
			{
				streamStart = stream.bytesRead;
				read(packSize);
				packable.fromPack(P!Pack(this));
			}
			_ready = true;
		}
		catch(Exception e)
		{
			_exception = e;
		}
	}

	uint calculatePackSize()
	{
		//Prevent stream modification
		R!Stream aside = stream;
		stream = cast(R!Stream)New!SingularityStream();
		packable.toPack(P!Pack(this));
		
		//Get results and restore stream
		uint result = stream.bytesWritten;
		stream = aside;
		return result;
	}
	
public:
	@property bool packing() { return stream.writable; }
	@property bool unpacking() { return stream.readable; }
	@property bool ready() { return _ready; }
	@property bool error() { return _exception ? true : false; }
	@property Exception exception() { return _exception; }
	@property double progress()
	{
		return cast(double) (
			packing ? stream.bytesWritten : stream.bytesRead
			- streamStart) / packSize; 
	}
	@property string activity() { return _activity; }
	@property void activity(string value) { _activity = value; }
	
	/**
	 * Write a struct or packable to the pack.
	 * 
	 * If the item does not define toPack, it is written
	 * as it appears in memory.
	 */
	final void write(T)(T data)
	{
		T[1] temp = (&data)[0..1];
		writeTuple(temp);
	}

	final void read(T)(ref T data)
	{
		T[1] temp = (&data)[0..1];
		readTuple(temp);
	}
	
	/**
	 * Write a fixed-length array of structs or packables.
	 * 
	 * If the items do not define toPack, they are written
	 * as they appear in memory.
	 */
	final void writeTuple(T)(T[] data)
	{
		static if(hasMember!(T, "toPack"))
			foreach(ref T packable; data)
				packable.toPack(P!Pack(this));
		else
			stream.write(data);
	}

	final void readTuple(T)(T[] data)
	{
		static if(hasMember!(T, "fromPack"))
			foreach(ref T packable; data)
				packable.fromPack(P!Pack(this));
		else
			stream.read(data);
	}

	/**
	 * Write an array of structs or packables.
	 * 
	 * If the items do not define toPack, they are written
	 * as they appear in memory.
	 */
	final void writeArray(T)(Array!T data)
	{
		write(data.size);
		writeTuple(data[]);
	}

	final void readArray(T)(ref Array!T data)
	{
		uint size;
		read(size);
		data.size = size;

		static if(is(T == class))
		{
			foreach(ref T packable; data) packable = New!T();
		}
		
		readTuple(data[]);
	}
}

final class PackException : Exception
{
	this(string msg)
	{
		super(msg);
	}
}
/* TODO Update tests
//Bug prevents compilation of UnittestB (depends on A) inside the unit test.
//http://d.puremagic.com/issues/show_bug.cgi?id=852
version(unittest)
{
	final class UnittestA : Packable
	{
		int[] array;
		int[3] tuple;
		double single;
		
		this()
		{
			array = [1,2,3,4,5];
			tuple = [6,7,8];
			single = 12.345678;
		}
		
		void zero()
		{
			array = [];
			tuple = [0,0,0];
			single = 0.0;
		}
		
		override void toPack(P!Pack pack)
		{
			pack.writeArray(array);
			pack.writeTuple(tuple);
			pack.write(single);
		}

		override void fromPack(P!Pack pack)
		{
			pack.readArray(array);
			pack.readTuple(tuple);
			pack.read(single);
		}
	}

	final class UnittestB : Packable
	{
		UnittestA[] array;
		
		this()
		{
			array = [new UnittestA, new UnittestA, new UnittestA];
			array[0].single = 0.0;
			array[0].array = [0,0];
			array[1].single = 1.1;
			array[1].array = [1,1];
			array[2].single = 2.2;
			array[2].array = [2,2];
		}
		
		void zero()
		{
			array = [];
		}
		
		void toPack(P!Pack pack)
		{
			pack.writeArray(array);
		}

		void fromPack(P!Pack pack)
		{
			pack.readArray(array);
		}
	}
}

unittest
{
	UnittestA a = new UnittestA();
	a.save("TestPackableA");
	a.zero;
	a.load("TestPackableA");
	
	assert(a.array == [1,2,3,4,5]);
	assert(a.tuple == [6,7,8]);
	assert(a.single == 12.345678);
	
	
	UnittestB b = new UnittestB();
	b.save("TestPackableB");
	b.zero;
	b.load("TestPackableB");
	
	assert(b.array[1].single == 1.1);
	assert(b.array[1].array == [1,1]);
	assert(b.array.length == 3);
}


*/