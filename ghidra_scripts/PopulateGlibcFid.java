// Populate a FID database from imported glibc archives, argument driven.
//
// Usage (headless postScript):
//   -scriptPath <dir> -postScript PopulateGlibcFid.java <fidbPath> [versionFilter]
//
// If versionFilter is given (e.g. 2.42), only that version folder is populated,
// which is how a small test database is built without touching the full one.
//
// Walks /glibc/<version>/<arch> in the current project and creates one FID
// library per version and arch. The language is inferred from the arch folder
// name (i386 -> x86:LE:32:default, anything else -> x86:LE:64:default). It uses
// the same FID service calls as the shipped CreateMultipleLibraries script, but
// takes all inputs as arguments so there are no interactive prompts to feed in
// headless mode.
//
// It rebuilds cleanly: an existing database at the given path is deleted first.
//@category FunctionID
import java.io.File;
import java.util.ArrayList;
import java.util.List;

import ghidra.app.script.GhidraScript;
import ghidra.feature.fid.db.FidDB;
import ghidra.feature.fid.db.FidFile;
import ghidra.feature.fid.db.FidFileManager;
import ghidra.feature.fid.db.LibraryRecord;
import ghidra.feature.fid.service.FidPopulateResult;
import ghidra.feature.fid.service.FidService;
import ghidra.framework.model.DomainFile;
import ghidra.framework.model.DomainFolder;
import ghidra.program.database.ProgramContentHandler;
import ghidra.program.model.lang.LanguageID;
import ghidra.util.task.TaskMonitor;

public class PopulateGlibcFid extends GhidraScript {

	private FidService service;

	@Override
	protected void run() throws Exception {
		String[] args = getScriptArgs();
		if (args.length < 1) {
			println("ERROR: first script argument must be the fidb path");
			return;
		}
		File dbFile = new File(args[0]);
		String versionFilter = (args.length >= 2) ? args[1] : null;

		service = new FidService();
		FidFileManager mgr = FidFileManager.getInstance();

		// Fresh build each run.
		if (dbFile.exists()) {
			println("Existing database found, deleting for a clean rebuild: " + dbFile);
			dbFile.delete();
		}
		mgr.createNewFidDatabase(dbFile);
		mgr.addUserFidFile(dbFile);

		FidFile fidFile = findFidFile(mgr, dbFile);
		if (fidFile == null) {
			println("ERROR: could not locate the registered fidb: " + dbFile);
			return;
		}

		DomainFolder root = getState().getProject().getProjectData().getRootFolder();
		DomainFolder glibc = root.getFolder("glibc");
		if (glibc == null) {
			println("ERROR: no /glibc folder in the project. Run the import step first.");
			return;
		}

		FidDB fidDb = fidFile.getFidDB(true);
		int librariesCreated = 0;
		int grandTotalAdded = 0;
		try {
			for (DomainFolder versionFolder : glibc.getFolders()) {
				String version = versionFolder.getName();
				if (versionFilter != null && !version.equals(versionFilter)) {
					continue;
				}
				for (DomainFolder archFolder : versionFolder.getFolders()) {
					monitor.checkCancelled();
					String arch = archFolder.getName();
					String langStr =
						arch.equals("i386") ? "x86:LE:32:default" : "x86:LE:64:default";
					LanguageID languageID = new LanguageID(langStr);

					ArrayList<DomainFile> programs = new ArrayList<>();
					findPrograms(programs, archFolder);
					println("glibc " + version + " " + arch + " (" + langStr + "): " +
						programs.size() + " programs");
					if (programs.isEmpty()) {
						continue;
					}

					FidPopulateResult result = service.createNewLibraryFromPrograms(fidDb,
						"glibc", version, arch, programs, null, languageID, null, null,
						TaskMonitor.DUMMY);
					grandTotalAdded += reportResult(result);
					librariesCreated++;
				}
			}
			fidDb.saveDatabase("glibc build", monitor);
		}
		finally {
			fidDb.close();
		}
		println("DONE: " + librariesCreated + " libraries, " + grandTotalAdded +
			" functions added, saved to " + dbFile);
	}

	private FidFile findFidFile(FidFileManager mgr, File dbFile) {
		List<FidFile> files = mgr.getUserAddedFiles();
		FidFile match = null;
		for (FidFile ff : files) {
			if (ff.toString().contains(dbFile.getName())) {
				match = ff;
			}
		}
		if (match == null && !files.isEmpty()) {
			match = files.get(files.size() - 1);
		}
		return match;
	}

	private int reportResult(FidPopulateResult result) {
		if (result == null) {
			return 0;
		}
		LibraryRecord lib = result.getLibraryRecord();
		if (lib != null) {
			println("  " + lib.getLibraryFamilyName() + ":" + lib.getLibraryVersion() + ":" +
				lib.getLibraryVariant());
		}
		println("  attempted=" + result.getTotalAttempted() + " added=" +
			result.getTotalAdded() + " excluded=" + result.getTotalExcluded());
		return (int) result.getTotalAdded();
	}

	private void findPrograms(ArrayList<DomainFile> programs, DomainFolder folder)
			throws Exception {
		if (folder == null) {
			return;
		}
		for (DomainFile df : folder.getFiles()) {
			monitor.checkCancelled();
			if (df.getContentType().equals(ProgramContentHandler.PROGRAM_CONTENT_TYPE)) {
				programs.add(df);
			}
		}
		for (DomainFolder sub : folder.getFolders()) {
			monitor.checkCancelled();
			findPrograms(programs, sub);
		}
	}
}
